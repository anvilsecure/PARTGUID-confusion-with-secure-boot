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

.PHONY: help env uboot fit kernel busybox rootfs image run demo all clean distclean \
        experiments partuuid partlabel verity-signed

help:
	@echo "Targets:"
	@echo "  env       build the Docker build-environment image"
	@echo "  all       busybox + rootfs + kernel + fit + uboot (in this order)"
	@echo "  uboot     build both signed U-Boots (env embedded) -> out/uboot-part{uuid,label}/"
	@echo "  fit       sign the kernel FIT + key the control DTB -> out/fit/"
	@echo "  kernel    build arm64 Linux Image            -> out/kernel/Image"
	@echo "  busybox   build static aarch64 busybox       -> out/busybox/busybox"
	@echo "  rootfs    assemble good+evil ext4 rootfs      -> out/rootfs/*.img"
	@echo "  image     craft GPT disk (STRATEGY=$(STRATEGY)) -> out/image/disk.img"
	@echo "  run       boot out/image/disk.img on host QEMU"
	@echo "  experiments  full matrix: BASELINE + PARTUUID + PARTLABEL + DM-VERITY (signed FIT)"
	@echo "  partuuid     BASELINE + PARTUUID group only"
	@echo "  partlabel    BASELINE + PARTLABEL group only"
	@echo "  verity-signed  the mitigation on its own: verity root hash in an RSA-signed FIT (good/evil/tamper)"
	@echo "  demo      all + image + run"
	@echo "  clean     remove out/ artifacts (keep vendored sources)"
	@echo "  distclean clean + remove fetched sources"

env:
	docker build -t $(IMG) docker/

# Two builds: the boot logic lives in U-Boot's embedded environment, and the env fixes
# how root= is expressed (PARTUUID derived from the verified partition, or PARTLABEL).
# The golden hash is baked in too, so U-Boot must be built AFTER the rootfs exists.
uboot: rootfs
	$(DRUN) scripts/build-uboot.sh partuuid
	$(DRUN) scripts/build-uboot.sh partlabel

# sign the kernel as a FIT and stamp the pubkey into the control DTB
fit: kernel
	$(DRUN) scripts/sign-kernel-fit.sh

kernel:
	$(DRUN) scripts/build-kernel.sh

busybox:
	$(DRUN) scripts/build-busybox.sh

rootfs: busybox
	$(DRUN) scripts/make-rootfs.sh

all: busybox rootfs kernel fit uboot

image: 
	$(DRUN) scripts/make-image.sh $(STRATEGY)

# run on the HOST, not in the container (host has qemu-system-aarch64 + a display path).
# The signed boot needs the FIT-verifying U-Boot and the key-bearing control DTB.
run:
	UBOOT=out/uboot-partuuid/u-boot.bin DTB=out/fit/keyed.dtb scripts/run-qemu.sh

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

demo: all image run

clean:
	rm -rf out/uboot out/kernel out/busybox out/rootfs out/image out/*.log

distclean: clean
	rm -rf src
