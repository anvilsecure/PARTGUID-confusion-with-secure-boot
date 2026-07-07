# Results

Reproduce with `make experiments` — one ordered, self-asserting suite:
1. `good-only` (boots) · 2. `evil-only` (rejected) · 3. hash bypass PARTUUID single-disk
(EVIL) · 4. hash bypass PARTLABEL multi-disk (EVIL) · 4b. hash bypass PARTUUID multi-disk
(EVIL) · 5. FIT bypass PARTUUID (EVIL) · 6. dm-verity mitigation (evil blocked + good
verified). Logs: `boot-good-only.log`, `boot-evil-only.log`, `boot-partuuid.log`,
`boot-mldisk.log`, `boot-mldisk-partuuid.log`, `boot-fit-partuuid.log`,
`boot-fit-tampered.log`, `boot-verity.log`, `boot-verity-good.log`.
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

## Model (matches RAT #116)

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

### Multi-disk PARTLABEL bypass — phase 4  ([boot-mldisk.log](boot-mldisk.log))

Two virtio disks, each with a partition labelled `rootfs`:

- `disk.img`  = QEMU hd0 → **U-Boot virtio 1 / Linux vdb** = GOLDEN rootfs.
- `disk2.img` = QEMU hd1 → **U-Boot virtio 0 / Linux vda** = attacker rootfs (+ boot slot).

Measured fact for qemu virt + virtio-mmio: **U-Boot and Linux enumerate the two disks
in the *same* (reversed-from-`-device`) order** — hd1 is "first" for both. So the bypass
is **not** from an ordering disagreement; it is from the vendor **policy**: U-Boot
verifies `rootfs` on the fixed golden disk it trusts (virtio 1), while Linux resolves
`root=PARTLABEL=rootfs` to the *first* match it enumerates (`vda` = the attacker disk):

```
 U-Boot: eMMC(virtio 1) rootfs VERIFIED OK -> U-Boot trusts the eMMC golden rootfs
 EXT4-fs (vda1): mounted filesystem baea5211-...f7d2 r/w      (= evil.img)
 #  ROOTFS IDENTITY : EVIL
```

U-Boot validated one disk; Linux mounted another.

### Multi-disk PARTUUID bypass — phase 4b  ([boot-mldisk-partuuid.log](boot-mldisk-partuuid.log))

The issue's exact wording: *"duplicate PARTUUID … on another drive connected to the same
system"*. Identical two-disk layout, but **both `rootfs` partitions carry the same unique
GUID** `11111111-…-555555555555` (built with `make-multidisk.sh partuuid`), and the
cmdline is `root=PARTUUID=11111111-…-555555555555`:

```
 U-Boot: eMMC(virtio 1) rootfs VERIFIED OK -> U-Boot trusts the golden rootfs
 Kernel command line: ... root=PARTUUID=11111111-2222-3333-4444-555555555555 ...
 EXT4-fs (vda1): mounted filesystem baea5211-...f7d2 r/w      (= evil.img)
 #  ROOTFS IDENTITY : EVIL
```

U-Boot verified the golden drive (virtio 1); Linux resolved the duplicated PARTUUID to
the first-enumerated drive (`vda` = attacker) and mounted the evil rootfs. This is the
strongest form of the confusion, because a *unique* partition GUID is precisely what
developers assume they can trust across drives.

Summary: PARTUUID is exploitable **single-disk** (phase 3) *and* **across two drives**
(4b); PARTLABEL needs the **two-disk** setup (4).

## `fit` — REAL RSA verified boot, still bypassed  ([boot-fit-partuuid.log](boot-fit-partuuid.log))

Same `partuuid` disk, but U-Boot now performs a **genuine RSA-2048 FIT signature
check** on the kernel (key in U-Boot's control DTB), on top of the rootfs hash check.
Built with `scripts/build-uboot-fitverify.sh` + `scripts/sign-fit.sh`; booted with
`out/uboot-fit/u-boot.bin` and `-dtb out/stage-b/keyed.dtb`.

```
 U-Boot: ROOTFS(name=rootfs) VERIFIED OK (golden partition)     (hash check, good = p3)
 ## Loading kernel from FIT Image at 44000000 ...
    Verifying Hash Integrity ... sha256,rsa2048:dev+ OK          (REAL RSA-2048 signature)
 ...
 EXT4-fs (vda1): mounted filesystem baea5211-...f7d2            (= evil.img)
 #  ROOTFS IDENTITY : EVIL
 *** ROOTFS VERIFICATION BYPASSED VIA PARTITION-ID CONFUSION ***
```

The kernel is **cryptographically signed and verified** (RSA-2048), and the rootfs
U-Boot inspects by name passes its hash check — yet Linux still runs the unsigned evil
partition via the duplicated PARTUUID. This is the bug against *real* verified boot:
signing the kernel does not protect the rootfs when the rootfs is located by a
re-resolvable, non-unique identifier.

### Negative control — verification is genuinely enforced  ([boot-fit-tampered.log](boot-fit-tampered.log))

Flip one byte in the kernel payload of the signed `kernel.itb` and boot:

```
    Verifying Hash Integrity ... sha256 error!
 Bad hash value for 'hash-1' hash node in 'kernel' image node
 Bad Data Hash
 ERROR -2: can't get kernel image!
```

U-Boot **refuses to boot** the tampered FIT (no kernel, no EVIL). So the `+ OK` above
is a real cryptographic verdict, not a cosmetic print — the bypass defeats verification
that is actually being enforced.

### qemu DTB note (why `keyed.dtb` is built from `live.dtb`)

FIT signature needs the pubkey in U-Boot's control FDT. On qemu that FDT comes from
QEMU, so we pass a key-bearing copy via `-dtb` (keeping `OF_BOARD` on, so the kernel
boots). Crucially, `qemu-system-aarch64 -machine dumpdtb` emits a **1 MiB** blob that
does **not** boot the kernel when fed back via `-dtb`; the DTB QEMU actually hands the
payload at boot is ~**8 KiB**. The lab extracts that live 8 KiB DTB from a working boot
(`/sys/firmware/fdt`, saved by init) and stamps the key into it (`out/stage-b/live.dtb`
→ `keyed.dtb`). Using the dumped blob leaves the kernel silent after `Starting kernel`.

An earlier variant embedded the key by disabling `OF_BOARD`
(`scripts/build-uboot-stageb.sh`) — kept for reference but off the default path, since
disabling `OF_BOARD` also lands on the non-booting embedded DTB.

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

Takeaway (matches the #116 mitigation notes): sign/verify the kernel *and* protect the
rootfs with dm-verity whose root hash is inside the signed boot artifacts — do not
trust a rootfs located by a duplicable PARTUUID/PARTLABEL.
