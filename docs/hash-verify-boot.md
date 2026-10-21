# Boot recipe — hash-verify (the confusion demos)

Used by the **BASELINE / PARTUUID / PARTLABEL** groups of `make experiments`. One boot
flow drives all of them; the scenario is defined by the disk layout
([`make-image.sh`](../scripts/make-image.sh) / [`make-multidisk.sh`](../scripts/make-multidisk.sh)).

This path models a vendor whose bootloader **verifies the rootfs it selects by name** and
then hands Linux a `root=` that Linux **re-resolves on its own** — and the two can land on
different partitions.

## Nothing security-relevant lives on the disk

There is **no boot script on the disk**. A `boot.scr` sits on an attacker-writable
partition, so verifying the rootfs from a disk-resident script would be a secure-boot
bypass in itself — the attacker would simply rewrite the script. Instead:

| piece | where it lives | how it is protected |
|-------|----------------|---------------------|
| boot logic (`bootcmd`, `verify_rootfs`, `setup_bootargs`) | compiled into the U-Boot binary (`CONFIG_ENV_SOURCE_FILE`) | trusted / read-only; U-Boot never reads an environment from storage (`CONFIG_ENV_IS_NOWHERE`) |
| golden hash | same embedded environment | same |
| kernel | `kernel.itb` in the boot slot | **RSA-2048 FIT signature**, key in the control FDT |
| rootfs content | data partition | the only thing the disk contributes — and the subject of this lab |

So every row of the matrix boots a **verified** chain. What remains exposed is exactly the
bug: the mapping from an identifier to a block device.

## The two steps that matter

From [`uboot/partguid.env.in`](../uboot/partguid.env.in). Everything else is plumbing.

**`verify_rootfs`** — find the partition by name and hash the **whole partition**:

```sh
part number virtio ${bootdev} ${rootname} rootpart;    # locate BY NAME
part start  virtio ${bootdev} ${rootpart} rootstart;
part size   virtio ${bootdev} ${rootpart} rootblocks;
setexpr rootbytes ${rootblocks} * 0x200;
virtio device ${bootdev};                              # 'virtio read' uses the CURRENT
virtio read ${rootbuf_addr} ${rootstart} ${rootblocks};#  device — select it explicitly
hash sha256 ${rootbuf_addr} ${rootbytes} vhash;
if test "${vhash}" = "${goodhash}"; then ... else reset; fi
```

The rootfs partitions are sized **exactly** like the rootfs images, so
`sha256(partition) == sha256(good.img) ==` the `goodhash` baked into U-Boot.

**`setup_bootargs`** — tell Linux where root is:

```sh
part uuid virtio ${bootdev}:${rootpart} rootuuid;      # the PARTUUID of the partition
setenv rootspec PARTUUID=${rootuuid};                  #  we JUST VERIFIED
setenv bootargs "console=${console} root=${rootspec} rootfstype=ext4 rootwait rw ..."
```

**This is the crux.** The bootloader does the reasonable thing: it verifies a partition and
passes Linux *that partition's own* identifier. It is still defeated, because GPT does not
enforce uniqueness — Linux resolves the same identifier to the **first** match, which can be
a different partition entirely.

(The PARTLABEL build is identical except that `setup_bootargs` uses
`root=PARTLABEL=${rootname}`; that is the only difference between the two U-Boot binaries.)

## Per-scenario outcomes

| scenario | disk layout | outcome |
|----------|-------------|---------|
| BASELINE good-only | one partition named `rootfs` = golden | hash OK → **GOOD** |
| BASELINE evil-only | one partition named `rootfs` = evil | hash ≠ golden → **refuse** |
| PARTUUID (single) | p1 evil + p3 golden **share PARTUUID X**; golden named `rootfs` | U-Boot verifies p3 and derives `root=PARTUUID=X`; Linux takes the first match = p1 → **EVIL** |
| PARTLABEL (single) | p1 evil + p3 golden **both named `rootfs`** | both resolvers pick the first `rootfs` = p1 → U-Boot **catches it** |
| PARTUUID / PARTLABEL (multi-disk) | internal golden (has the boot slot) + attacker USB (rootfs only) | U-Boot boots and verifies the internal disk; Linux enumerates the USB first → **EVIL** |

On a single disk the divergence comes from **different selectors** (U-Boot by GPT name vs
Linux by PARTUUID); across two disks it comes from **different scope** (U-Boot looks only at
the disk it booted from, Linux first-matches across all of them). In QEMU both resolvers
agree on enumeration order, so neither case depends on a race. See [ANALYSIS.md](ANALYSIS.md).

The mitigation is in [signed-verity-boot.md](signed-verity-boot.md).
