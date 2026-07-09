# Boot recipe — hash-verify (the confusion demos)

Used by the **BASELINE / PARTUUID / PARTLABEL** groups of `make experiments` (and `make image
… && make run`). One boot script drives all of them; the scenario is defined by the disk
layout ([`make-image.sh`](../scripts/make-image.sh) / [`make-multidisk.sh`](../scripts/make-multidisk.sh))
and the `root=` spec baked into the script.

This path models a vendor whose bootloader **verifies the rootfs it selects by name/slot** and
then hands Linux a `root=<spec>` that Linux **re-resolves on its own** — the two can land on
different partitions. (`verify_image` is modelled with `hash sha256` over a marker file, a
stand-in for a signature; the confusion is identical regardless of the crypto used.)

## A) U-Boot `bootcmd` — compiled into U-Boot

From [`configs/uboot.fragment`](../configs/uboot.fragment) (`CONFIG_BOOTCOMMAND`): scan the
virtio disks for a `boot.scr` and `source` the first one found, recording the device in
`${bootdev}`.

```sh
virtio scan
setenv bootdev 0; ext4load virtio 0:2 ${scriptaddr} /boot.scr && source ${scriptaddr}
setenv bootdev 1; ext4load virtio 1:2 ${scriptaddr} /boot.scr && source ${scriptaddr}
```

This models a device that boots from whichever medium carries the boot slot: single disk →
`bootdev=0`; device + attacker USB → the USB (virtio 0) has no boot slot, so U-Boot falls
through to the internal disk on virtio 1 (`bootdev=1`).

## B) The boot script — [`uboot/boot.cmd`](../uboot/boot.cmd)

A template with `@@…@@` placeholders, compiled to `boot.scr` by `make-image.sh` (via `mkimage`):

```sh
# load_kernel from the boot slot
ext4load virtio ${bootdev}:2 ${kernel_addr_r} /Image

# load_rootfs + verify_image: locate the rootfs BY NAME '@@ROOTNAME@@' and hash its marker
ext4load virtio ${bootdev}#@@ROOTNAME@@ 0x46000000 /etc/rootfs-id
hash sha256 0x46000000 ${filesize} vhash
if test "${vhash}" = "@@GOODHASH@@"; then
    echo " ROOTFS VERIFIED OK -> U-Boot TRUSTS '@@ROOTNAME@@'"
else
    echo " ROOTFS VERIFICATION FAILED -> refusing to boot"
    reset                                   # refuse (a shell would itself be a bypass)
fi

# setup_bootargs: Linux locates root BY @@ROOTSPEC@@ — re-resolved INDEPENDENTLY
setenv bootargs "console=ttyAMA0 root=@@ROOTSPEC@@ rootfstype=ext4 rootwait rw init=/sbin/init panic=-1 partguid.verified"
booti ${kernel_addr_r} - ${fdtcontroladdr}
```

**The crux**: U-Boot verifies the partition it found **by name** (`#@@ROOTNAME@@`), then tells
Linux to mount **by `@@ROOTSPEC@@`**. When those resolve to different partitions, U-Boot
verified one and Linux mounts another.

## Where the variables come from

- **`@@…@@` = build-time** (substituted by `make-image.sh` with `sed`, so they are literal
  strings in the compiled `boot.scr`):

  | placeholder | set to | by |
  |-------------|--------|----|
  | `@@ROOTNAME@@` | `rootfs` | `ROOTNAME=rootfs` |
  | `@@GOODHASH@@` | sha256 of the golden marker | `sha256sum rootfs/good/etc/rootfs-id` |
  | `@@ROOTSPEC@@` | `PARTUUID=<guid>` or `PARTLABEL=rootfs` | per scenario |

- **`${…}` = runtime U-Boot env**: `${bootdev}` set by the bootcmd (which disk); `${scriptaddr}`,
  `${kernel_addr_r}`, `${fdtcontroladdr}` are the board's default env (see `printenv`);
  `${filesize}` is set by the load command; `vhash` is set by `hash`.

## Per-scenario parameterization

| scenario | `@@ROOTSPEC@@` | disk layout | outcome |
|----------|----------------|-------------|---------|
| BASELINE good-only | `PARTUUID=X` | one `rootfs` = golden | verify OK → **GOOD** |
| BASELINE evil-only | `PARTUUID=X` | one `rootfs` = evil | hash ≠ golden → **refuse** |
| PARTUUID (single) | `PARTUUID=X` | p1 evil + p3 golden **share PARTUUID X**; golden named `rootfs` | U-Boot verifies p3 (by name), Linux picks p1 (first PARTUUID match) → **EVIL** |
| PARTLABEL (single) | `PARTLABEL=rootfs` | p1 evil + p3 golden **both named `rootfs`** | both resolvers pick the first `rootfs` → agree → U-Boot **catches it** |
| PARTUUID / PARTLABEL (multi-disk) | as above | internal golden (has boot slot) + attacker USB (rootfs only) | U-Boot verifies the internal disk it booted; Linux enumerates the USB first → **EVIL** |

Note: on a single disk the divergence comes from **different selectors** (U-Boot by GPT name
vs Linux by PARTUUID), not from the same identifier resolving in a different order — in QEMU
both resolvers agree on enumeration order. See [ANALYSIS.md](ANALYSIS.md).

## Threat-model caveat (state this in the writeup)

Here `boot.scr` sits on a **writable** partition. The demo is only a faithful model of the bug
if you assume the boot chain (bootloader + script + cmdline) is **signed/verified** while the
partition table and rootfs are not — otherwise an attacker would just edit `boot.scr`. The
[signed dm-verity recipe](signed-verity-boot.md) makes that boundary real (signed cmdline, no
writable script) and shows the fix.
