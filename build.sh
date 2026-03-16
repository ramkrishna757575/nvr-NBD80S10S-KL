#!/bin/bash
set -e

# ── Configuration ────────────────────────────────────────────────────────────
ARCH=arm
CROSS_COMPILE=arm-linux-gnueabihf-
JOBS=$(nproc)

LINUX_REPO=https://github.com/linux-chenxing/linux.git
LINUX_BRANCH=mstar_v6_5_rebase
BUSYBOX_VER=1.36.1
BUSYBOX_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2
DROPBEAR_VER=2022.83
DROPBEAR_URL=https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VER}.tar.bz2

SCRIPT_DIR=$(dirname "$(realpath "$0")")
BUILD_DIR=$SCRIPT_DIR/build
OUTPUT_DIR=$SCRIPT_DIR/output

mkdir -p $BUILD_DIR $OUTPUT_DIR

# ── Kernel ────────────────────────────────────────────────────────────────────
echo "=== [1/5] Building kernel ==="
if [ ! -d $BUILD_DIR/linux ]; then
    git clone --depth=1 -b $LINUX_BRANCH $LINUX_REPO $BUILD_DIR/linux
fi
cd $BUILD_DIR/linux

# Apply patches (ignore if already applied)
for patch in $SCRIPT_DIR/patches/*.patch; do
    git apply --check $patch 2>/dev/null && git apply $patch || true
done

cp $SCRIPT_DIR/config/kernel.config .config
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE -j$JOBS zImage
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
    sigmastar/mstar-infinity2m-ssr621d-tlnvr.dtb dtbs

cat arch/arm/boot/zImage \
    arch/arm/boot/dts/sigmastar/mstar-infinity2m-ssr621d-tlnvr.dtb \
    > /tmp/zImage-dtb

mkimage -A arm -O linux -T kernel -C none \
    -a 0x20008000 -e 0x20008000 \
    -n "Linux-chenxing" \
    -d /tmp/zImage-dtb \
    $OUTPUT_DIR/uImage-chenxing

echo "Kernel built: $(ls -lh $OUTPUT_DIR/uImage-chenxing | awk '{print $5}')"

# ── BusyBox ───────────────────────────────────────────────────────────────────
echo "=== [2/5] Building BusyBox ==="
if [ ! -d $BUILD_DIR/busybox ]; then
    wget -qO- $BUSYBOX_URL | tar xj -C $BUILD_DIR
    mv $BUILD_DIR/busybox-${BUSYBOX_VER} $BUILD_DIR/busybox
fi
cd $BUILD_DIR/busybox
cp $SCRIPT_DIR/config/busybox.config .config
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE -j$JOBS
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE install

# ── Dropbear ──────────────────────────────────────────────────────────────────
echo "=== [3/5] Building Dropbear ==="
if [ ! -d $BUILD_DIR/dropbear ]; then
    wget -qO- $DROPBEAR_URL | tar xj -C $BUILD_DIR
    mv $BUILD_DIR/dropbear-${DROPBEAR_VER} $BUILD_DIR/dropbear
fi
cd $BUILD_DIR/dropbear
# Password auth is enabled by default; no localoptions.h override needed.
if [ ! -f Makefile ] || [ ! -f dropbear ]; then
    ./configure --host=arm-linux-gnueabihf \
        --disable-zlib --disable-shadow --disable-pam \
        --enable-static --disable-syslog \
        LDFLAGS="-static" CC=arm-linux-gnueabihf-gcc
fi
make -j$JOBS PROGRAMS="dropbear dropbearkey"

# ── Rootfs ────────────────────────────────────────────────────────────────────
echo "=== [4/5] Assembling rootfs ==="
ROOTFS=$BUILD_DIR/rootfs
rm -rf $ROOTFS
mkdir -p $ROOTFS

# Base: busybox
cp -a $BUILD_DIR/busybox/_install/* $ROOTFS/

# Overlay: our config files
cp -a $SCRIPT_DIR/rootfs-overlay/* $ROOTFS/

# Dropbear binaries
mkdir -p $ROOTFS/usr/sbin $ROOTFS/usr/bin
cp $BUILD_DIR/dropbear/dropbear $ROOTFS/usr/sbin/
cp $BUILD_DIR/dropbear/dropbearkey $ROOTFS/usr/bin/

# Host keys are generated at first boot by dropbear -R (written to /tmp/dropbear).

# Required directories
mkdir -p $ROOTFS/{proc,sys,dev,tmp,root,mnt/newroot}
ln -sf bin/busybox $ROOTFS/linuxrc

# ── Flash images ──────────────────────────────────────────────────────────────
echo "=== [5/5] Packing flash images ==="

# romfs: kernel squashfs
mkdir -p $BUILD_DIR/romfs/boot
cp $OUTPUT_DIR/uImage-chenxing $BUILD_DIR/romfs/boot/uImage
mksquashfs $BUILD_DIR/romfs $OUTPUT_DIR/romfs-x.squashfs.img \
    -comp xz -b 262144 -all-root -noappend

# user: rootfs squashfs
mksquashfs $ROOTFS $OUTPUT_DIR/user-x.squashfs.img \
    -comp xz -b 262144 -all-root -noappend

# USB rootfs: full rootfs + USB init
USB_ROOTFS=$OUTPUT_DIR/usb-rootfs
rm -rf $USB_ROOTFS
cp -a $ROOTFS $USB_ROOTFS
cp $SCRIPT_DIR/usb-rootfs/init $USB_ROOTFS/init
chmod +x $USB_ROOTFS/init
mkdir -p $USB_ROOTFS/oldroot $USB_ROOTFS/mnt/newroot

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Build complete ==="
echo ""
echo "Output files:"
ls -lh $OUTPUT_DIR/*.img $OUTPUT_DIR/uImage-chenxing
echo ""
echo "Flash to NVR board (via U-Boot TFTP):"
echo "  tftpboot 0x22000000 uImage-chenxing"
echo "  sf erase 0x50000 0x3F0000 && sf write 0x22000000 0x50000 \${filesize}"
echo "  tftpboot 0x22000000 user-x.squashfs.img"
echo "  sf erase 0x440000 0xBC0000 && sf write 0x22000000 0x440000 \${filesize}"
echo ""
echo "Set up USB drive:"
echo "  sudo mkfs.ext4 -F /dev/sdX1"
echo "  sudo cp -a output/usb-rootfs/* /mnt/"
