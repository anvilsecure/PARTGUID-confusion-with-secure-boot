# Results

Reproduce with `make experiments` — a self-asserting matrix: the confusion groups (by
**identifier type**) plus the DM-VERITY mitigation group (QEMU enumeration is deterministic
so each row is single-shot). Run one confusion group with `make partuuid` or `make partlabel`
(each also runs the shared BASELINE rows).

* **BASELINE** — 4 rows. *single disk:* good-only (GOOD) · evil-only (refused). *multi disk
  (device + attacker USB):* internal-only (GOOD) · internal-evil (refused). These show the
  verification genuinely accepts good and rejects evil, so the bypass rows matter.
* **PARTUUID** — 2 rows: single-disk (EVIL) · multi-disk (EVIL). Exploitable even on one
  disk.
* **PARTLABEL** — 2 rows: single-disk (U-Boot catches → no boot) · multi-disk (EVIL). The
  single-disk row is kept precisely to show the bypass **fails** there (both resolvers pick
  the first `rootfs`, so U-Boot verifies the same partition Linux would mount and catches
  the evil copy); the two-disk case is where PARTLABEL bypasses.
* **DM-VERITY** (mitigation) — 3 rows: good passes; the confused partition is blocked with a
  `panic` (single-disk PARTUUID, multi-disk PARTLABEL). Also runnable on its own with
  `make verity`.

**Multi-disk model = router + attacker USB (realistic):** the device's internal media
holds the boot slot (kernel) and the golden rootfs and boots on its own; the attacker
USB carries only a rootfs (no boot slot). U-Boot's bootcmd scans the disks, skips the
USB (no boot script), boots the internal disk and verifies its golden rootfs — but Linux
enumerates the USB first and mounts its evil rootfs. The `internal-only` / `internal-evil`
baselines boot the internal disk alone (GOOD / U-Boot-rejects).

Logs in `results/`: `boot-{good,evil}-only.log`, `boot-partuuid.log`,
`boot-partlabel.log`, `boot-mldisk-{good-only,evil-only,partuuid,partlabel}.log`,
`boot-verity{,-good,-mldisk}.log`.
Env: U-Boot 2024.07 (`qemu_arm64`), Linux 6.6, busybox 1.36.1, QEMU `-M virt`, virtio-blk.

## Baselines (phases 1–2) — the verification is real

- **good-only** ([boot-good-only.log](boot-good-only.log)): the only `rootfs` partition is
  the golden one. U-Boot's by-name hash check passes and the **GOOD** rootfs boots. So a
  correct system works.
- **evil-only** ([boot-evil-only.log](boot-evil-only.log)): the only `rootfs` partition is
  evil. U-Boot's hash of the marker ≠ golden → `ROOTFS VERIFICATION FAILED -> resetting`.
  The system does **not** boot. So the check is meaningful — it rejects a bad rootfs.

The bypass phases below matter *because* of these baselines: verification genuinely
accepts good and rejects evil, yet the confusion makes Linux mount evil anyway.

## Model

U-Boot's boot script:
1. loads the kernel from a fixed boot slot,
2. locates the rootfs **by name** (partlabel `rootfs`) and **verifies** it
   (modelled with `hash sha256` of a marker file — a stand-in for a signature check),
3. sets `root=<spec>` for Linux and boots (`booti`, using QEMU's control FDT).

The gap: U-Boot verifies the partition it found **by name**, but Linux re-resolves
`<spec>` (PARTUUID or PARTLABEL) **independently**, and can mount a *different*
partition. The verified partition and the mounted partition are not the same one.

## Ground truth (filesystem UUIDs)

```
good.img = bea2b942-ba54-415a-871e-ee6447cee9ab
evil.img = baea5211-314e-4d7d-ba6c-63f56f83f7d2
```
Cross-check the `EXT4-fs (vdaN): mounted filesystem <uuid>` line against these to tie
each boot to good/evil independently of the banner text.

## Scenario `partuuid` — the exploit  ([boot-partuuid.log](boot-partuuid.log))

Disk: p1 `rootfs-decoy` PARTUUID=**X** (evil), p2 `boot`, p3 `rootfs` PARTUUID=**X** (good).
Both p1 and p3 carry the same unique GUID `11111111-…-555555555555`.
cmdline: `root=PARTUUID=11111111-…-555555555555`.

```
 U-Boot: rootfs(name=rootfs) marker sha256 = 462bba11...0d9   (matches golden)
 U-Boot: ROOTFS VERIFIED OK -> U-Boot TRUSTS the partition named 'rootfs'   (= p3, good)
 ...
 EXT4-fs (vda1): mounted filesystem baea5211-...f7d2 r/w       (= evil.img)
 VFS: Mounted root (ext4 filesystem) on device 254:1.          (254:1 = vda1)
 #  ROOTFS IDENTITY : EVIL
 *** ROOTFS VERIFICATION BYPASSED VIA PARTITION-ID CONFUSION ***
```

U-Boot verified **p3** (good, found by name `rootfs`). Linux resolved the duplicated
PARTUUID to the first match = **vda1** (evil). fs-UUID `baea5211` confirms it is
`evil.img`, not the verified partition. **The check passed and unsigned code still ran
as root.** This is the single-disk PARTUUID exploit — trivial to craft (GPT does not
enforce PARTUUID uniqueness) and requires only that the attacker copy sit at a lower
partition index than the golden one.

## Scenario `partlabel` — variation  ([boot-partlabel.log](boot-partlabel.log))

Disk: p1 `rootfs` (evil, GUID A), p2 `boot`, p3 `rootfs` (good, GUID B) — two
partitions sharing the **name** `rootfs`. cmdline: `root=PARTLABEL=rootfs`.

```
 U-Boot: rootfs(name=rootfs) marker sha256 = 4d823152...633   (= evil's marker, NOT golden)
 U-Boot: ROOTFS VERIFICATION FAILED -> refusing to boot
 resetting ...
```

On a **single disk**, both resolvers pick the *first* partition named `rootfs` (p1).
Because they **agree**, U-Boot verifies the same partition Linux would mount — so
U-Boot's check catches the evil copy and halts. No divergence.

⇒ PARTLABEL is **not** exploitable on a single disk (first-match wins for both).

### Multi-disk bypass — router + attacker USB  ([boot-mldisk-partlabel.log](boot-mldisk-partlabel.log), [boot-mldisk-partuuid.log](boot-mldisk-partuuid.log))

Realistic setup — a device with internal media plus an inserted attacker USB stick:

- `disk.img`  = **internal media** (eMMC): p1 golden rootfs + **p2 boot slot** (kernel).
  QEMU hd0 → U-Boot virtio 1 / Linux vdb. Boots on its own.
- `disk2.img` = **attacker USB**: p1 evil rootfs, **no boot slot**. QEMU hd1 → U-Boot
  virtio 0 / Linux vda. Both partitions labelled `rootfs` (PARTLABEL case) or sharing
  the same PARTUUID `1111…5555` (PARTUUID case — the classic "duplicate PARTUUID on
  another drive connected to the same system").

U-Boot's bootcmd scans the disks for `boot.scr`: the USB (virtio 0) has no boot slot, so
U-Boot falls through to the internal disk (virtio 1) and boots it — `${bootdev}=1`:

```
 ** Invalid partition 2 **                                   (virtio 0 = USB, no boot slot)
 U-Boot booted from virtio 1 ...                             (fell through to internal media)
 U-Boot: ROOTFS VERIFIED OK -> ... on virtio 1              (verified the internal golden rootfs)
 EXT4-fs (vda1): mounted filesystem baea5211-...f7d2 r/w     (= evil.img, the USB)
 #  ROOTFS IDENTITY : EVIL
```

U-Boot booted **and verified** the internal golden rootfs, yet Linux enumerated the USB
(`vda`) first and mounted **its** evil rootfs. The attacker only had to insert a
rootfs-only USB and reboot — no bootloader/kernel on the stick.

Baselines (`internal-only`, `internal-evil`) boot the internal disk **alone**: golden →
**GOOD**; evil → U-Boot's verify fails → **no boot**. The attacker USB by itself is not
bootable (no boot slot), which is exactly why the attack needs the device's own trusted
boot chain.

Summary: PARTUUID is exploitable **single-disk** *and* across two drives; PARTLABEL needs
the two-disk case (single-disk PARTLABEL is caught).

## Why signing the kernel isn't the fix

The bypass is orthogonal to the strength of the boot-chain crypto. Even with a genuinely
signed kernel (e.g. an RSA-signed FIT), U-Boot can only verify what it **loads into RAM** —
the kernel, the DTB, a ramdisk. It never loads the block-device rootfs; Linux mounts that
later by re-resolving `root=`. So U-Boot verifies the golden rootfs it found *by name*, the
signed kernel boots fine, and Linux still mounts the evil partition it resolved *by
identifier*. Signing the kernel raises the bar for tampering with the *kernel* — not for
the rootfs the identifier points at. The real fix binds rootfs integrity to the mounted
content, below.

## Mitigation — dm-verity blocks the confusion  (`make verity`, [boot-verity.log](boot-verity.log))

The correct fix binds root integrity to a **cryptographic hash**, not to a
re-resolvable partition identifier. The kernel maps root through dm-verity via the
`dm-mod.create=` command line (no initramfs); the verity **data device is still located
by `PARTUUID`** (so the confusion still selects the evil partition), but the verity
**root hash is the hash of the GOLDEN rootfs**.

Kernel is built with `CONFIG_BLK_DEV_DM=y CONFIG_DM_VERITY=y CONFIG_DM_INIT=y`. The
hash tree is built over `good.img` with `veritysetup`; cmdline:

```
root=/dev/dm-0 ro rootwait ... dm-mod.create="vroot,,0,ro,0 65536 verity 1
  PARTUUID=11111111-...-555555555555 /dev/vda4 4096 4096 8192 1 sha256 <ROOTHASH> <SALT>
  1 panic_on_corruption"
```

Result:

```
 device-mapper: ioctl: dm-0 (vroot) is ready
 device-mapper: verity: 254:1: data block 0 is corrupted     (254:1 = vda1 = evil)
 Kernel panic - not syncing: dm-verity device corrupted
```

dm-verity opened the evil partition (vda1) as the verity data device, hashed its first
block, found it did **not** match the golden root hash, and **panicked** — the evil
rootfs never ran (no `ROOTFS IDENTITY : EVIL` in the log). Even though Linux still
resolved the duplicated PARTUUID to the attacker partition, integrity was bound to a
hash, so the wrong partition is rejected.

Takeaway: sign/verify the kernel *and* protect the rootfs with dm-verity whose root hash
is inside the signed boot artifacts — do not trust a rootfs located by a duplicable
PARTUUID/PARTLABEL. Plain `make verity` proves the *mechanism*, but its root hash rides in
an unsigned `boot.scr`; the **complete solution** below anchors it in a signed FIT.

## Complete solution — root hash in a signed FIT  (`make verity-signed`)

`make verity` leaves one gap: the dm-verity root hash lives in `boot.scr` on a writable
partition, so an attacker who can rewrite the disk could weaken the verity cmdline. The
complete fix puts the verity cmdline (root hash) inside an **RSA-2048 signed FIT** and has
U-Boot `bootm` it directly — it does not `source` a writable script, so the root hash
cannot be substituted. Built by `scripts/make-verity-signed.sh`; U-Boot from
`scripts/build-uboot-fitverify.sh` (CONFIG_FIT_SIGNATURE, key in the control DTB via `-dtb`).

Three boots, all asserted:

- **good** ([boot-vsigned-good.log](boot-vsigned-good.log)): `Verifying Hash Integrity ...
  sha256,rsa2048:dev+ OK` (FIT signature verified) → verity passes the golden data →
  `ROOTFS IDENTITY : GOOD`. The signed path boots.
- **evil** ([boot-vsigned-evil.log](boot-vsigned-evil.log)): FIT verified (`rsa2048:dev+ OK`),
  yet under the same PARTUUID collision `device-mapper: verity: 254:1: data block 0 is
  corrupted` → `Kernel panic: dm-verity device corrupted`. Evil blocked.
- **tamper** ([boot-vsigned-tamper.log](boot-vsigned-tamper.log)): flip one byte in the
  signed FIT → the config signature is structurally valid but the payload hash fails
  (`Bad Data Hash` / `can't get kernel image`) → U-Boot refuses and resets. The FIT
  (kernel **and** the fdt carrying the root hash) is integrity-protected — the tamper here
  targets the kernel payload; the root-hash-bearing fdt rides under the identical signature.

Now both holes are closed: an attacker who supplies a colliding rootfs is caught by verity
(evil panics), and an attacker who rewrites the boot artifact to weaken verity breaks the
signature (tamper refused). Diagram: [docs/solution.jpg](docs/solution.jpg).
