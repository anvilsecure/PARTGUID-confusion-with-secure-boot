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
[docs/mechanism.svg](docs/mechanism.svg).

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

`make experiments` runs the whole story as one ordered, self-asserting suite:

| # | phase                         | expected                                                    |
|---|-------------------------------|-------------------------------------------------------------|
| 1 | `good-only`                   | golden rootfs → U-Boot verifies OK → **GOOD boots** (baseline: verification works) |
| 2 | `evil-only`                   | evil rootfs → U-Boot hash-verify **FAILS → no boot** (baseline: verification is meaningful) |
| 3 | hash bypass / **PARTUUID**    | dup PARTUUID on one disk → **EVIL mounted** (verify passed on good, Linux mounted evil) |
| 4 | hash bypass / **PARTLABEL**   | two disks sharing label `rootfs` → **EVIL mounted** (U-Boot verifies the golden disk, Linux mounts the attacker disk) |
| 4b| hash bypass / **PARTUUID** (multi-disk) | two disks sharing one PARTUUID (duplicate GUID on another drive) → **EVIL mounted** |
| 5 | FIT bypass / **PARTUUID**     | **real RSA-2048** signed kernel verified, yet **EVIL mounted** |
| 6 | dm-verity **mitigation**      | evil **rejected** (`panic: dm-verity device corrupted`) + good **verified & booted** |

Each phase's boot log is committed under `results/`. Single scenarios also run
standalone: `make fit`, `make verity`, `make mldisk` (multi-disk PARTLABEL), or
`make image STRATEGY=partuuid && make run`.

Note on PARTLABEL (phase 4): on a **single** disk both U-Boot and Linux pick the first
`rootfs`, so they agree and U-Boot catches the evil copy — no divergence. The bypass
needs **two disks**: U-Boot verifies a fixed golden disk by policy while Linux resolves
`PARTLABEL=rootfs` to the first-enumerated disk (the attacker's). PARTUUID, by contrast,
is exploitable on a single disk.

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
