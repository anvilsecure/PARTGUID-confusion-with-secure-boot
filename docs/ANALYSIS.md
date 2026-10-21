# PARTGUID / PARTUUID confusion under secure boot — analysis

## What "secure boot" actually guarantees here

In a typical U-Boot verified-boot design the chain of trust is:

```
ROM/SPL  --verifies-->  U-Boot  --verifies (FIT signature)-->  kernel + DTB + boot script
```

The *boot script* (or the FIT's embedded `bootargs`) carries the kernel command
line, including `root=PARTUUID=<X>`. Because the script is inside the signed FIT,
the command line is itself integrity-protected: an attacker cannot change the
**string** `root=PARTUUID=<X>`.

What is **not** signed, and is recomputed independently by Linux at runtime, is the
mapping:

```
   PARTUUID=<X>   ───►   a concrete block device (/dev/vdaN)
```

U-Boot computes one mapping (or doesn't use PARTUUID at all — it may load the kernel
from a fixed slot it considers golden). Linux computes its own mapping in
`block/early-lookup.c` / `init/do_mounts.c` (`devt_from_partuuid`). **The trust chain
covers the bytes of the command line but not the resolution of the identifier inside
it.** That is the gap.

## Why the two resolvers can disagree

`root=PARTUUID=` is resolved by Linux by walking registered block partitions and
returning the **first** device whose GPT *unique partition GUID* matches. GPT does
**not** enforce uniqueness of that GUID — the spec only says it *should* be unique.
So a disk can legally contain two partitions with the same unique GUID.

Sources of divergence the lab is built to probe:

1. **First-match vs fixed-slot (implemented: `dup-partuuid`).** U-Boot loads/verifies
   from a fixed golden slot (a partition number or label). Linux resolves the
   duplicated PARTUUID to the *first* matching partition. Place the attacker's
   partition at a lower index than the golden slot and Linux selects it while U-Boot
   never consulted the PARTUUID at all.

2. **Primary vs backup GPT (planned: `backup-gpt`).** Parsers differ on when they
   fall back to the backup GPT header/entries. If U-Boot trusts the primary table
   and Linux (or libblkid) falls back to the backup, the two describe different
   partitions for the same slot.

3. **Type GUID vs unique GUID (planned: `type-vs-unique`).** Boot logic that selects
   "the partition of type *Linux root (arm64)*" keys off the *type* GUID, whereas
   `root=PARTUUID=` keys off the *unique* GUID. Two partitions of the same type, one
   unsigned, defeat the assumption.

4. **Hybrid/protective MBR (planned: `hybrid-mbr`).** A hybrid MBR can present a
   different partition view to code that reads the MBR than to code that reads the
   GPT.

## The lab's demonstration (`dup-partuuid`)

Disk:

| part | label      | unique GUID                              | role                                   |
|------|------------|------------------------------------------|----------------------------------------|
| p1   | root-evil  | `11111111-2222-3333-4444-555555555555`   | attacker rootfs, lowest index          |
| p2   | boot       | (unique)                                 | U-Boot's fixed golden boot slot        |
| p3   | root-good  | `11111111-2222-3333-4444-555555555555`   | the rootfs U-Boot intends to trust     |

U-Boot's embedded environment (there is no script on the disk) locates the partition named
`rootfs`, hashes it against a golden hash compiled into that environment, and then sets
`root=PARTUUID=...` from **that partition's own GUID** — here
`11111111-2222-3333-4444-555555555555`. U-Boot's job is to validate the golden artifacts;
it does. Linux then resolves that same PARTUUID to **p1**, the attacker's partition, and
runs its `/sbin/init`.

The two rootfs images print a loud banner identifying themselves, so a single boot
log shows: signed kernel + intact signed cmdline → **EVIL** rootfs mounted.

### Reading the result

* U-Boot console prints `part list virtio 0` and the PARTUUID it baked into the
  cmdline.
* Linux `/sbin/init` prints `ROOTFS IDENTITY`, `/proc/cmdline`, and the device
  actually mounted at `/`.
* Vulnerable outcome: identity is `EVIL` while the cmdline PARTUUID is the golden
  one.

## Caveats / things to verify empirically (this is why it's a *lab*)

* Linux's "first match" order depends on block-device registration order, which for a
  single virtio disk is ascending partition number — hence the attacker partition is
  placed at p1 (`devt_from_partuuid` in `block/early-lookup.c`). This is why the
  `partuuid` scenario works: U-Boot verifies the partition it finds *by name*
  (`rootfs` = p3, good), while Linux's `root=PARTUUID=X` picks the first match (p1,
  evil). See [results/RESULTS.md](../results/RESULTS.md).
* The `partlabel` scenario shows the limit: on a single disk both U-Boot's `#rootfs`
  and Linux's `PARTLABEL=rootfs` pick the *first* match, so they agree and U-Boot's
  verification catches the evil copy. Exploiting PARTLABEL needs multiple disks whose
  enumeration order differs between U-Boot and Linux.
* Whether a given U-Boot version consults the PARTUUID itself (and would therefore
  *also* pick p1, collapsing the divergence) depends on the boot script. The lab
  deliberately models the fixed-slot pattern.
* Real targets often add dm-verity over the rootfs, which would catch this. The
  finding applies to the (common) designs that trust "the right partition" by
  identifier alone. Document the target's actual design before claiming impact.

## Remediation talking points (for the eventual writeup)

* Bind the rootfs into the chain of trust directly (dm-verity root hash inside the
  signed FIT), not by partition identifier.
* Have the bootloader pass `root=` by the device path/slot it actually verified, not
  by a re-resolvable PARTUUID/PARTLABEL.
* Reject disks with duplicate partition GUIDs; prefer matching that is identical
  across bootloader and kernel.
