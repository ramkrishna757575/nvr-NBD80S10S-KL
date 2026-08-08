#!/bin/sh
# Buildroot track for the ground station.
#
# This is the build. It produces the flashable, signed uImage in output/.
#
# The kernel is the vendor SigmaStar 4.9.84 tree, handed to buildroot through
# LINUX_OVERRIDE_SRCDIR so nothing is downloaded and the vendor tree is only
# ever read from.
set -e

SCRIPT_DIR=$(dirname "$(realpath "$0")")
BUILD_DIR=$SCRIPT_DIR/build
EXT_DIR=$SCRIPT_DIR/buildroot-ext
BR_DIR=$BUILD_DIR/buildroot
BR_OUT=$BUILD_DIR/buildroot-out
SDK_ROOT=$BUILD_DIR/sdk
KERNEL_DIR=$SDK_ROOT/sigmastar/kernel/4.9.84
TOOLCHAIN_BIN=$BUILD_DIR/toolchain/armv7-eabihf--glibc--stable-2018.11-1/bin
JOBS=$(nproc)

# 2025.02 LTS rather than something older: host gcc 15 cannot compile the
# m4 1.4.19 that buildroot 2023.02 pins, and m4 is pulled in by libpcap through
# bison and flex. 2025.02 carries m4 1.4.21 and still offers the gcc 7.x and
# 4.1-headers external toolchain options this board needs.
BUILDROOT_REF=2025.02.x

if [ ! -d "$BR_DIR" ]; then
    echo "=== Fetching buildroot $BUILDROOT_REF ==="
    git clone --depth 1 --branch $BUILDROOT_REF \
        https://github.com/buildroot/buildroot.git "$BR_DIR"
fi

for d in "$KERNEL_DIR" "$TOOLCHAIN_BIN"; do
    [ -d "$d" ] || { echo "error: missing $d -- run fetch-deps.sh first" >&2; exit 1; }
done

# The Bootlin tarball ships host tools too -- bison, m4, gawk, tar -- built with
# a /opt prefix that does not exist here, so its bison cannot find m4sugar.m4.
# Buildroot finds the cross tools through BR2_TOOLCHAIN_EXTERNAL_PATH, so keep
# the toolchain's bin directory off PATH entirely and let the host tools win.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' |
       grep -v 'armv7-eabihf--glibc--stable-2018.11-1' | paste -sd:)

# This distribution's /usr/bin/install is uutils, which buildroot refuses over
# a known bug (uutils/coreutils#12166). GNU install is here as gnuinstall, so
# shadow it rather than asking for update-alternatives and root.
HOSTBIN=$BUILD_DIR/hostbin
mkdir -p $HOSTBIN
if [ -x /usr/bin/gnuinstall ]; then
    ln -sf /usr/bin/gnuinstall $HOSTBIN/install
fi

# build/shim/python is a symlink to python3, so the kernel Makefile finds a "python".
export PATH=$HOSTBIN:$BUILD_DIR/shim:$PATH

# ── Vendor kernel patches ─────────────────────────────────────────────────────
# Guarded, so a tree that has already been patched is left alone.
echo "=== [1/3] Patching the SigmaStar kernel tree ==="

# $1 = marker to test for, $2 = file to test it in, $3 = patch file
apply_sdk_patch() {
    grep -q "$1" "$2" 2>/dev/null && return 0
    patch -p1 -d $SDK_ROOT < $SCRIPT_DIR/patches/$3 ||
        { echo "error: $3 did not apply" >&2; exit 1; }
}

apply_sdk_patch "name=b'#MS_DTB#'" "$KERNEL_DIR/scripts/ms_builtin_dtb_update.py" \
    0007-sdk-python3-build-scripts.patch
apply_sdk_patch "mstar_gpio_request" "$KERNEL_DIR/drivers/sstar/gpio/mdrv_gpio_io.c" \
    0008-sdk-gpio-mstar-aliases.patch
apply_sdk_patch "piu_timer_for_vdec" "$KERNEL_DIR/arch/arm/boot/dts/infinity2m.dtsi" \
    0009-sdk-dts-piu-timer.patch

# 0010 only deletes a line, so the guard is inverted: apply while it is still there.
if grep -q '^YYLTYPE yylloc;' "$KERNEL_DIR/scripts/dtc/dtc-lexer.l"; then
    patch -p1 -d $SDK_ROOT < $SCRIPT_DIR/patches/0010-sdk-dtc-yylloc.patch ||
        { echo "error: 0010-sdk-dtc-yylloc.patch did not apply" >&2; exit 1; }
fi

# ── Point buildroot at the vendor tree ────────────────────────────────────────
# Buildroot rsyncs this into its own build dir and builds there, so the SDK
# tree is only ever read. Build products are excluded so a tree that has
# already been compiled in does not carry stale objects across.
echo "=== [2/3] Writing $BUILD_DIR/local.mk ==="
cat > $BUILD_DIR/local.mk <<EOF
LINUX_OVERRIDE_SRCDIR = $KERNEL_DIR
LINUX_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \\
	--exclude=.config --exclude=.config.old --exclude=.version \\
	--exclude=*.o --exclude=*.ko --exclude=*.cmd --exclude=.tmp_*
EOF

# ── Build ─────────────────────────────────────────────────────────────────────
echo "=== [3/3] Building ==="
# BR2_EXTERNAL only has to be passed when the configuration is created; it is
# recorded in the output directory from then on.
make -C $BR_DIR O=$BR_OUT BR2_EXTERNAL=$EXT_DIR ssr621q_fpv_defconfig
# The rsync of the vendor tree is a stamped, once-only step, so without this a
# later patch to build/sdk is never seen and the build quietly uses the old copy.
rm -f $BR_OUT/build/linux-custom/.stamp_rsynced
make -C $BR_OUT -j$JOBS

# post-image.sh has already validated and signed these; copy them out under the
# stable names the flashing instructions and CI refer to. The signature is only
# there if a key was available, which in CI it is not -- that step signs later.
mkdir -p $SCRIPT_DIR/output
cp $BR_OUT/images/uImage $SCRIPT_DIR/output/uImage
if [ -f $BR_OUT/images/uImage.sig ]; then
    cp $BR_OUT/images/uImage.sig $SCRIPT_DIR/output/uImage.sig
else
    rm -f $SCRIPT_DIR/output/uImage.sig
fi

echo
echo "images:"
ls -la $BR_OUT/images/
echo
echo "flashable: output/uImage ($(stat -c %s $SCRIPT_DIR/output/uImage) bytes)"
