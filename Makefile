# partguid-confusion-lab
#
# Builds run inside the Docker build-environment (`make env`); the resulting
# artifacts are booted on the HOST qemu-system-aarch64 (`make run`).

SHELL        := /bin/bash
IMG          := partguid-lab:latest
PWD          := $(shell pwd)
STRATEGY     ?= partuuid

# Run a command inside the build container with the repo bind-mounted at /work.
DRUN         := docker run --rm -t -v "$(PWD)":/work -w /work $(IMG)

.PHONY: help env uboot kernel busybox rootfs image run demo all clean distclean \
        experiments partuuid partlabel verity-signed mldisk

help:
	@echo "Targets:"
	@echo "  env       build the Docker build-environment image"
	@echo "  all       uboot + kernel + busybox + rootfs"
	@echo "  uboot     build U-Boot for qemu_arm64        -> out/uboot/u-boot.bin"
	@echo "  kernel    build arm64 Linux Image            -> out/kernel/Image"
	@echo "  busybox   build static aarch64 busybox       -> out/busybox/busybox"
	@echo "  rootfs    assemble good+evil ext4 rootfs      -> out/rootfs/*.img"
	@echo "  image     craft GPT disk (STRATEGY=$(STRATEGY)) -> out/image/disk.img"
	@echo "  run       boot out/image/disk.img on host QEMU"
	@echo "  experiments  full matrix: BASELINE + PARTUUID + PARTLABEL + DM-VERITY (signed FIT)"
	@echo "  partuuid     BASELINE + PARTUUID group only"
	@echo "  partlabel    BASELINE + PARTLABEL group only"
	@echo "  verity-signed  the mitigation on its own: verity root hash in an RSA-signed FIT (good/evil/tamper)"
	@echo "  mldisk    one scenario: multi-disk PARTLABEL bypass"
	@echo "  demo      all + image + run"
	@echo "  clean     remove out/ artifacts (keep vendored sources)"
	@echo "  distclean clean + remove fetched sources"

env:
	docker build -t $(IMG) docker/

uboot:
	$(DRUN) scripts/build-uboot.sh

kernel:
	$(DRUN) scripts/build-kernel.sh

busybox:
	$(DRUN) scripts/build-busybox.sh

rootfs: busybox
	$(DRUN) scripts/make-rootfs.sh

all: uboot kernel busybox rootfs

image:
	$(DRUN) scripts/make-image.sh $(STRATEGY)

# run on the HOST, not in the container (host has qemu-system-aarch64 + a display path)
run:
	scripts/run-qemu.sh

# build + boot the attack and both control scenarios; assert each mounted rootfs.
experiments:
	scripts/experiments.sh

# one confusion group (each also runs the shared BASELINE rows first)
partuuid:
	scripts/experiments.sh partuuid
partlabel:
	scripts/experiments.sh partlabel

# MITIGATION (complete): dm-verity whose root hash is anchored in an RSA-signed FIT
# (golden boots, evil panics, a tampered signed FIT is refused)
verity-signed:
	scripts/verity-signed-demo.sh

# multi-disk PARTLABEL: U-Boot verifies the eMMC rootfs, Linux mounts the SD's rootfs
mldisk:
	scripts/mldisk-demo.sh

demo: all image run

clean:
	rm -rf out/uboot out/kernel out/busybox out/rootfs out/image out/*.log

distclean: clean
	rm -rf src
