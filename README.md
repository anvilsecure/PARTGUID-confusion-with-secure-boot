# partguid-confusion-lab

A reproducible QEMU harness for **PARTGUID / PARTUUID confusion under secure boot**.

## The bug class in one paragraph

Many embedded boot designs split responsibility for the root filesystem across two
components that resolve "which partition" *independently*:

* **U-Boot** (the bootloader) loads and — under verified boot — cryptographically
  validates the kernel and a *boot script that bakes in `root=PARTUUID=<X>`*. It
  decides which partition is the "golden" one by some rule (a fixed slot number, a
  partition label, a type GUID, the primary GPT header, ...).
* **Linux** later resolves the same `root=PARTUUID=<X>` on its own, using the
  kernel's `name_to_dev_t` / GPT parser, to decide which block device to mount as
  `/`.

If an attacker who can write the partition table (exposed update/recovery partition,
A/B logic, physical access, a writable data partition adjacent to root) can make
these two resolvers **disagree**, then U-Boot trusts the intended partition while
Linux mounts a *different*, attacker-controlled one. The kernel and its command line
can be genuinely signed — the integrity gap is the unsigned mapping from "PARTUUID"
to "block device", and the fact that two parsers compute it differently.

This lab builds the smallest end-to-end system that exhibits the divergence and lets
us characterize *which* GPT shapes are vulnerable — see
[results/RESULTS.md](results/RESULTS.md). The mechanism at a glance:
[docs/mechanism.png](docs/mechanism.png).

The boot flow models a typical vendor `bootcmd`: U-Boot loads the kernel,
locates the rootfs **by name** (`#rootfs`) and **verifies** it (a `sha256` check
standing in for a signature), then boots Linux with `root=<spec>`. Linux re-resolves
`<spec>` on its own and can mount a *different* partition.

## Scenarios

| scenario   | GPT                                              | outcome |
|------------|--------------------------------------------------|---------|
| `partuuid` | two partitions share one PARTUUID; good is named `rootfs` (p3), evil copy at p1 | **EVIL mounted** — U-Boot verifies `rootfs` (good), Linux resolves `root=PARTUUID=X` to the first match (evil). The exploit. |
| `partlabel`| two partitions both named `rootfs` (distinct PARTUUIDs), `root=PARTLABEL=rootfs` | **U-Boot catches it** — on one disk both resolvers pick the first `rootfs`, so verification fails on the evil copy. Exploiting PARTLABEL needs multiple disks with divergent enumeration. |

## Layout

```
docker/Dockerfile        build environment (debian + aarch64 cross + gdisk + u-boot-tools)
configs/kernel.fragment  extra kernel .config options (ext4, gpt, virtio, devtmpfs)
scripts/build-uboot.sh   build U-Boot for qemu_arm64
scripts/build-kernel.sh  build a minimal arm64 Linux Image
scripts/build-busybox.sh build a static aarch64 busybox
scripts/make-rootfs.sh   assemble good/ and evil/ ext4 rootfs images
scripts/make-image.sh    craft the GPT disk for a scenario (partuuid|partlabel)
scripts/run-qemu.sh      launch on the host's qemu-system-aarch64
uboot/boot.cmd           U-Boot boot script: verify rootfs by name, boot by @@ROOTSPEC@@
rootfs/{good,evil}/      per-rootfs overlay (init banner + identity marker)
out/                     build artifacts (gitignored)
```

## Quick start

```sh
make env          # build the Docker build-environment image (once)
make all          # build uboot + kernel + busybox + rootfs
make experiments  # build+boot both scenarios and assert the outcome
# or a single scenario, interactively:
make image STRATEGY=partuuid   # craft out/image/disk.img
make run                       # boot it on the host under QEMU, -nographic
```

`make experiments` runs the whole matrix as one self-asserting suite: the confusion groups
(by identifier type) plus the DM-VERITY mitigation group (every row is single-shot — QEMU
enumeration is deterministic). Run one confusion group with `make partuuid` or `make
partlabel` (each also runs the shared BASELINE rows; DM-VERITY runs only under `make
experiments`).

**BASELINE** — verification accepts the golden rootfs and rejects an evil one:

| # | row | expected |
|---|-----|----------|
| 1 | good-only | golden rootfs → verify OK → **GOOD boots** |
| 2 | evil-only | evil rootfs → hash-verify **FAILS → no boot** |
| 5 | multi-disk internal-only | device's internal disk alone (boot slot + golden rootfs) → **GOOD boots** |
| 6 | multi-disk internal-evil | internal disk carries an evil rootfs → verify **FAILS → no boot** |

**PARTUUID** — duplicate-PARTUUID bypass:

| # | row | expected |
|---|-----|----------|
| 3 | PARTUUID single-disk | dup PARTUUID on one disk → **EVIL** |
| 7 | PARTUUID multi-disk | internal (golden, boots) + attacker USB (dup PARTUUID) → **EVIL** |

**PARTLABEL** — caught single-disk, bypassed multi-disk:

| # | row | expected |
|---|-----|----------|
| 4 | PARTLABEL single-disk | both resolvers pick the first `rootfs` → U-Boot **catches it → no boot** |
| 8 | PARTLABEL multi-disk | internal (golden, boots) + attacker USB (same label) → **EVIL** |

**DM-VERITY (signed FIT)** — the mitigation: the verity root hash lives inside an RSA-signed FIT:

| row | expected |
|-----|----------|
| verity-signed good | FIT verified (`rsa2048:dev+ OK`) + verity passes golden data → **GOOD boots** |
| verity-signed / PARTUUID | FIT verified, evil data fails the hash → **panic: dm-verity device corrupted** (evil blocked) |
| verity-signed / tamper | one byte flipped in the signed FIT → **U-Boot refuses** (`Bad Data Hash`) |

Each row's boot log is committed under `results/`. The mitigation also runs on its own with
`make verity-signed`. Other standalone scenarios: `make mldisk [partuuid]`, or `make image
STRATEGY=partuuid && make run`.

The **multi-disk** rows (5–8) model the realistic attack — an embedded device (e.g. a
router) plus an **attacker USB stick**:

* The device's **internal media** (`disk.img`) holds the boot slot (kernel) *and* the
  golden rootfs, and boots on its own — that's the `internal-only` baseline.
* The **attacker USB** (`disk2.img`) carries **only a rootfs** (no boot slot) — the
  attacker just inserts it and reboots.
* U-Boot's bootcmd scans the disks for the boot script: the USB has none, so U-Boot
  boots the internal disk and verifies *its* golden rootfs — yet Linux enumerates the
  USB first and mounts *its* evil rootfs (same PARTUUID or PARTLABEL). The verified
  medium and the mounted medium differ.

Single-disk PARTLABEL (row 4) can't bypass: both resolvers pick the first `rootfs`, so
U-Boot verifies exactly what Linux would mount and catches the evil copy. PARTUUID is
exploitable even on a single disk (row 3); PARTLABEL needs the two-disk case (row 8).

### QEMU determinism

On `-M virt` the multi-disk demos are **deterministic**: U-Boot and Linux enumerate the
transports in the same order, so the divergence is a *policy* one (fixed-slot verify vs
first-match root) and reproduces on every run. On real hardware the same bug class can
also arise from genuine *enumeration-order* disagreement between the bootloader and Linux
(different probe/search orders across transports); this lab pins the stable policy variant.

Boot logs are committed under `results/` with a `sha256`/QEMU-version provenance header.

## Verification model

U-Boot's `verify_image` is modelled with `hash sha256` over a marker in the rootfs it
selects **by name** — a stand-in for a signature check. The *strength* of that check is
deliberately orthogonal to the bug: the confusion is about *which partition* is selected,
not about the crypto. Whether U-Boot validates the golden rootfs with a hash or a real
signature, it still verifies the partition it found *by name*, while Linux mounts the one
it resolves *by identifier* — a different partition. (This is also why signing the *kernel*
doesn't help: U-Boot can only verify what it loads into RAM, never the block-device rootfs
that Linux mounts later.)

The correct fix binds rootfs integrity to the **content Linux actually mounts**, not to a
re-resolvable identifier: **dm-verity** with the root hash carried in a *signed* boot
artifact. `make verity-signed` is the complete solution — the verity cmdline (root hash)
lives inside an **RSA-2048 signed FIT** that U-Boot `bootm`s directly (no writable `boot.scr`
to override it). Three asserted boots: under the same PARTUUID collision the golden data
**boots**, the attacker data **panics** (verity hash mismatch), and a **tampered signed FIT
is refused** (signature enforced). Both holes are shut — a colliding rootfs is caught by
verity, and rewriting the boot artifact to weaken verity breaks the signature. Mechanism of
the fix at a glance: [docs/solution.jpg](docs/solution.jpg). See `results/RESULTS.md`.

## Boot scripts

The exact U-Boot boot logic for each path, annotated (what U-Boot loads, verifies, and how
`root=` is set):

* [docs/hash-verify-boot.md](docs/hash-verify-boot.md) — the **BASELINE / PARTUUID / PARTLABEL**
  demos: `uboot/boot.cmd` verifies the rootfs by name (hash) and hands Linux a re-resolvable
  `root=`.
* [docs/signed-verity-boot.md](docs/signed-verity-boot.md) — the **mitigation**: no `boot.scr`;
  the verity root hash rides in an RSA-signed FIT that U-Boot `bootm`s directly.

See `docs/ANALYSIS.md` for the detailed mechanism writeup.
