# Boot recipe — signed dm-verity (the mitigation)

Used by `make verity-signed` (and the DM-VERITY group of `make experiments`). This is the
**complete fix**: the dm-verity root hash is anchored in an **RSA-2048 signed FIT**, so an
attacker who rewrites the disk cannot weaken it.

## There is no `boot.scr`

Unlike the hash-verify path (see [hash-verify-boot.md](hash-verify-boot.md)), this path has
**no boot script on disk**. A `boot.scr` lives on a writable partition, so an attacker could
edit it to drop `dm-verity` or point `root=` elsewhere — the confusion would be moot. Instead
the boot logic is split into two **trusted** pieces:

| piece | where it lives | how it is protected |
|-------|----------------|---------------------|
| boot logic (`bootcmd`) | compiled into the U-Boot binary | trusted / read-only (in a real device, verified by ROM/SPL) |
| **verity root hash** (kernel cmdline) | `/chosen/bootargs` of the fdt inside the FIT | **RSA-2048 signature** — tamper it → `Bad Data Hash` → U-Boot refuses |
| kernel | image inside the FIT | RSA-2048 signature |
| rootfs content | data partition | dm-verity vs the signed root hash → mismatch = kernel panic |

## A) U-Boot `bootcmd` — compiled into U-Boot

From [`configs/uboot-fitverify.fragment`](../configs/uboot-fitverify.fragment)
(`CONFIG_BOOTCOMMAND`, one line; shown here split for readability):

```sh
setenv bootargs                        # clear env bootargs so the kernel uses the SIGNED
                                       # fdt's /chosen/bootargs verbatim (fdt_chosen won't
                                       # overwrite when env bootargs is unset)
virtio scan
# load the signed FIT and RSA-verify it, then boot it (the fdt comes from the FIT):
ext4load virtio 0:2 0x44000000 /kernel.itb && bootm 0x44000000#conf-1
ext4load virtio 1:2 0x44000000 /kernel.itb && bootm 0x44000000#conf-1
# nothing verified booted -> reset (dropping to a shell would itself be a bypass):
echo "*** no verified FIT booted (rejected/absent) — resetting ***"
reset
```

`bootm …#conf-1` prints `Verifying Hash Integrity … sha256,rsa2048:dev+ OK` and refuses to
boot if the signature does not verify. It does **not** `source` a writable script.

## B) The verity cmdline — inside the signed FIT's fdt (`/chosen/bootargs`)

This is where the root hash lives. One line (split for readability); real values from a build:

```sh
console=ttyAMA0 root=/dev/dm-0 ro rootwait panic=-1 partguid.verified
dm-mod.create="vroot,,0,ro,0 65536 verity 1
  PARTUUID=11111111-2222-3333-4444-555555555555   # data dev: Linux re-resolves this (→ evil)
  /dev/vda4                                        # hash dev: the Merkle tree (golden)
  4096 4096 8192 1 sha256
  e2cf417003e2cff08cdcc70c080577480f3384a9fbbd8debe136264df502628a   # ROOT HASH of GOLDEN (signed)
  3bf5b8a6dae09485a56b888ce28662bd97169f3651e25609947154fb7cbe70c3   # salt
  1 panic_on_corruption"
```

(The root hash and salt are per-build — `veritysetup format` over the golden rootfs.)

## How B is built and signed

From [`scripts/make-verity-signed.sh`](../scripts/make-verity-signed.sh):

```sh
# 1. verity hash tree over the GOLDEN rootfs -> root hash + salt
veritysetup format --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
    --data-blocks=8192 good.img hash.img

# 2. put the verity cmdline (root hash) into the fdt's /chosen/bootargs
fdtput -p -t s verity.dtb /chosen bootargs "$CMDLINE"

# 3. FIT { kernel, fdt=verity.dtb } signed RSA-2048; pubkey stamped into the control DTB
mkimage -f verity.its -k keys -K keyed.dtb -r kernel.itb
#   verity.its:  configurations { conf-1 { kernel="kernel"; fdt="fdt-1";
#                  signature { algo="sha256,rsa2048"; sign-images="kernel","fdt"; }; }; }
```

`sign-images = "kernel", "fdt"` → the signature covers the kernel **and** the fdt carrying the
root hash. U-Boot boots with `-bios out/uboot-fit/u-boot.bin -dtb out/stage-b/keyed.dtb` (the
keyed DTB is U-Boot's control FDT, where `FIT_SIGNATURE` finds the public key).

## Outcomes (all asserted)

| boot | result |
|------|--------|
| **good** ([boot-vsigned-good.log](../results/boot-vsigned-good.log)) | `rsa2048:dev+ OK` + verity passes golden → `ROOTFS IDENTITY : GOOD` |
| **evil** ([boot-vsigned-evil.log](../results/boot-vsigned-evil.log)) | `rsa2048:dev+ OK`, but evil data fails verity → `Kernel panic: dm-verity device corrupted` |
| **tamper** ([boot-vsigned-tamper.log](../results/boot-vsigned-tamper.log)) | one byte flipped in the FIT → `Bad Data Hash` → U-Boot refuses and resets |

Both holes are shut: a colliding rootfs is caught by verity, and rewriting the boot artifact to
weaken verity breaks the RSA signature. Diagram: [docs/solution.jpg](solution.jpg).
