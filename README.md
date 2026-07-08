# partguid-confusion-lab

A reproducible QEMU harness for **PARTGUID / PARTUUID confusion under secure boot**
(anvilventures/RAT issue #116).

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

The boot flow models the vendor `bootcmd` from the issue: U-Boot loads the kernel,
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

`make experiments` runs the whole matrix (19 rows) as one self-asserting suite, grouped
by verification mechanism (every row is single-shot — QEMU enumeration is deterministic).
Run a single group with `scripts/experiments.sh ub|fit|dv` (each is quicker than `all`).

**Hash** — hash-based verify (Stage-A U-Boot, `booti`):

| # | row | expected |
|---|-----|----------|
| 1 | good-only | golden rootfs → verify OK → **GOOD boots** (baseline: verification works) |
| 2 | evil-only | evil rootfs → hash-verify **FAILS → no boot** (baseline: verification is meaningful) |
| 3 | hash bypass / PARTUUID | dup PARTUUID, one disk → **EVIL** |
| 4 | PARTLABEL single-disk | both resolvers pick the first `rootfs` → U-Boot **catches it → no boot** |
| 5 | multi-disk internal-only | device's internal disk alone (boot slot + golden rootfs) → **GOOD boots** |
| 6 | multi-disk internal-evil | internal disk carries an evil rootfs → verify **FAILS → no boot** |
| 7 | hash bypass / PARTUUID multi-disk | internal (golden, boots) + attacker USB (dup PARTUUID) → **EVIL** |
| 8 | hash bypass / PARTLABEL multi-disk | internal (golden, boots) + attacker USB (same label) → **EVIL** |

**FIT** — real RSA-2048 signed kernel + rootfs hash (`uboot-fit` + `-dtb`, `bootm`): the
**same eight rows**, each additionally showing `Verifying Hash Integrity ... rsa2048:dev+
OK` — so a genuinely signed kernel does not save the rootfs (bypass rows still mount EVIL).

**DM-VERITY** — the mitigation (root bound to a hash via `dm-mod.create=`):

| # | row | expected |
|---|-----|----------|
| 1 | verity PASSES good | genuine golden data → verity OK → **GOOD boots** |
| 2 | verity / PARTUUID | attacker partition selected → **`panic: dm-verity device corrupted`** (evil blocked) |
| 3 | verity / PARTLABEL multi-disk | attacker disk selected → **panic** (evil blocked) |

Each row's boot log is committed under `results/`. Single scenarios also run standalone:
`make fit`, `make verity`, `make mldisk [partuuid]` (multi-disk), or
`make image STRATEGY=partuuid && make run`.

The **multi-disk** rows model the realistic attack — an embedded device (e.g. a router)
plus an **attacker USB stick**:

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
exploitable even on a single disk (rows 3); PARTLABEL needs the two-disk case (row 8).

### QEMU determinism, `REPEAT`, and real hardware

On `-M virt` the multi-disk demos are **deterministic**: U-Boot and Linux enumerate the
transports in the same order, so the divergence is a *policy* one (fixed-slot verify vs
first-match root) and passes every run. Genuine *enumeration-order* disagreement (the
issue's "U-Boot … different search orders than Linux") is a real-hardware phenomenon.

* `REPEAT=n make mldisk` boots up to `n` times and stops at the first evil mount
  (`WANT` regex) — the "pass if it happens once" method. In QEMU it matches on try 1
  (deterministic); on hardware with a USB-vs-SD probe race it catches the divergent
  boot. `run-qemu.sh` also takes `USBDISK=<img>` to attach a USB drive (Linux `/dev/sda`),
  the software analogue of SD-vs-USB.
* For the authentic hardware reproduction (Raspberry Pi, SD golden vs USB attacker),
  see [docs/raspberry-pi-repro.md](docs/raspberry-pi-repro.md).

Boot logs are committed under `results/` with a `sha256`/QEMU-version provenance header.

## Verification model

Two levels, both showing the same bypass:

* **Default (`make experiments`):** U-Boot's `verify_image` is modelled with
  `hash sha256` over a marker in the rootfs it selects **by name** — a stand-in for a
  signature check. Fast, and the #116 confusion is about *which partition* is
  selected, not the crypto.
* **Real crypto (`make fit`):** U-Boot performs a **genuine RSA-2048 FIT signature
  check** on the kernel (key in its control DTB) on top of the rootfs hash check, and
  a negative control proves it *refuses* a tampered FIT. The evil rootfs is still
  mounted via the PARTUUID collision — so signing the kernel does not save you when
  the rootfs is located by a re-resolvable identifier. See `results/RESULTS.md`.

  qemu detail: the pubkey must live in U-Boot's control FDT, supplied via `-dtb`.
  `qemu ... -machine dumpdtb` emits a 1 MiB blob that won't boot the kernel; the lab
  instead extracts the ~8 KiB DTB QEMU really uses (from `/sys/firmware/fdt` on a
  working boot) and keys that. `scripts/build-uboot-stageb.sh` (embed key by disabling
  `OF_BOARD`) is kept for reference but off the default path.

See `docs/ANALYSIS.md` for the detailed mechanism writeup.
