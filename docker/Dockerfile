# Build environment for the partguid-confusion-lab.
#
# Everything that needs a Linux toolchain or GPT tooling runs here. The resulting
# artifacts (u-boot.bin, kernel Image, ext4 rootfs, GPT disk image) are written to
# the bind-mounted ./out and then booted by the *host's* qemu-system-aarch64.
#
# Built for linux/arm64 to match an Apple-Silicon host (native, no emulation).
FROM debian:bookworm

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git make gcc g++ \
        gcc-aarch64-linux-gnu \
        u-boot-tools device-tree-compiler \
        bc bison flex libssl-dev libgnutls28-dev \
        gdisk fdisk parted dosfstools mtools e2fsprogs cryptsetup-bin \
        cpio xz-utils bzip2 file kmod \
        python3 python3-pyelftools swig libncurses-dev \
    && rm -rf /var/lib/apt/lists/*

# mke2fs -d lets us populate ext4 images from a directory without root/loop mounts,
# which is exactly what an unprivileged container needs.
ENV CROSS_COMPILE=aarch64-linux-gnu-
ENV ARCH=arm64
WORKDIR /work
