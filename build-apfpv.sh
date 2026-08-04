#!/bin/bash
#
# Cross-compile wpa_supplicant for APFPV mode.
#
# APFPV is the simple OpenIPC mode: the air unit runs a WiFi AP and the ground
# station joins it as an ordinary station, so video arrives as plain UDP/RTP over
# IP. No monitor mode, no injection, no keys, no FEC -- which is why it is worth
# getting working before wfb-ng.
#
# BusyBox already provides udhcpc/ip/route/ifconfig, so wpa_supplicant is the
# only missing piece.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR=$SCRIPT_DIR/build
OUT=$BUILD_DIR/apfpv-out
SRC=$BUILD_DIR/apfpv-src

TOOLCHAIN_BIN=$BUILD_DIR/toolchain/armv7-eabihf--glibc--stable-2018.11-1/bin
CROSS_COMPILE=arm-buildroot-linux-gnueabihf-
HOST_TRIPLET=arm-buildroot-linux-gnueabihf

LIBNL_VER=3.7.0
WPA_VER=2.10
IW_VER=5.19

export PATH=$TOOLCHAIN_BIN:$BUILD_DIR/shim:$PATH

# Same toolchain-shadowing problem as build-wfb.sh. The Buildroot toolchain
# bundles bison/flex whose data dirs point at /opt/... from the machine that
# built it, and its own pkg-config wrapper that forces PKG_CONFIG_LIBDIR to the
# toolchain sysroot -- which silently ignores our libnl prefix and leaves iw with
# no -I flags. Shadow all of them with the host copies.
HOSTBIN=$BUILD_DIR/hostbin
mkdir -p $HOSTBIN
for t in bison flex m4 yacc lex pkg-config pkgconf; do
    [ -x /usr/bin/$t ] && ln -sf /usr/bin/$t $HOSTBIN/$t
done
export PATH=$HOSTBIN:$PATH

export CC=${CROSS_COMPILE}gcc
export AR=${CROSS_COMPILE}ar
export RANLIB=${CROSS_COMPILE}ranlib

command -v $CC >/dev/null || { echo "toolchain not found in $TOOLCHAIN_BIN"; exit 1; }

mkdir -p $SRC $OUT/bin

# ── libnl ─────────────────────────────────────────────────────────────────────
# wpa_supplicant talks to this driver over nl80211, which needs libnl. (The wext
# backend is also compiled in as a fallback, but nl80211 is what the cfg80211
# side of the rtl8812au driver actually implements properly.)
if [ ! -f $OUT/lib/libnl-3.a ]; then
    echo "=== [1/2] libnl $LIBNL_VER ==="
    cd $SRC
    [ -f libnl-$LIBNL_VER.tar.gz ] || wget -q \
        https://github.com/thom311/libnl/releases/download/libnl${LIBNL_VER//./_}/libnl-$LIBNL_VER.tar.gz
    rm -rf libnl-$LIBNL_VER
    tar xf libnl-$LIBNL_VER.tar.gz
    cd libnl-$LIBNL_VER
    ./configure --host=$HOST_TRIPLET --prefix=$OUT \
                --disable-shared --enable-static --disable-cli >/dev/null
    make -j$(nproc) >/dev/null
    make install >/dev/null
    echo "libnl installed"
else
    echo "=== [1/2] libnl already built ==="
fi

# ── wpa_supplicant ────────────────────────────────────────────────────────────
echo "=== [2/2] wpa_supplicant $WPA_VER ==="
cd $SRC
[ -f wpa_supplicant-$WPA_VER.tar.gz ] || \
    wget -q https://w1.fi/releases/wpa_supplicant-$WPA_VER.tar.gz
rm -rf wpa_supplicant-$WPA_VER
tar xf wpa_supplicant-$WPA_VER.tar.gz
cd wpa_supplicant-$WPA_VER/wpa_supplicant

# Deliberately minimal: WPA/WPA2-PSK only, which is all an FPV air unit AP uses.
# TLS/crypto are the bundled internal implementations so we do not have to
# cross-compile OpenSSL for what would be entirely unused EAP support.
cat > .config <<EOF
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=y
CONFIG_LIBNL32=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_PEERKEY=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_NO_RANDOM_POOL=y
CONFIG_IEEE80211W=y
CFLAGS += -I$OUT/include/libnl3
# -lpthread is explicit because we link libnl statically: libnl-3.a pulls in
# pthread_rwlock_* and static archives do not carry their own dependencies, so
# the link fails with "DSO missing from command line" without it.
LIBS += -L$OUT/lib -lpthread -lm
EOF

make -j$(nproc) \
    CC=${CROSS_COMPILE}gcc \
    LD=${CROSS_COMPILE}ld \
    AR=${CROSS_COMPILE}ar \
    wpa_supplicant wpa_cli \
    || { echo "wpa_supplicant build failed" >&2; exit 1; }

cp wpa_supplicant wpa_cli $OUT/bin/
${CROSS_COMPILE}strip $OUT/bin/* 2>/dev/null || true

# ── iw ────────────────────────────────────────────────────────────────────────
# The standard wireless tool. libnl is already built for wpa_supplicant, so this
# is nearly free -- and it is what OpenIPC's sbc-groundstations scripts call
# (set_power.sh, channel selection, list_wifi_channels), so having it means their
# tooling drops in unchanged instead of being reimplemented.
if [ ! -f $OUT/bin/iw ]; then
    echo "=== [3/3] iw $IW_VER ==="
    cd $SRC
    [ -f iw-$IW_VER.tar.xz ] || \
        wget -q https://www.kernel.org/pub/software/network/iw/iw-$IW_VER.tar.xz
    rm -rf iw-$IW_VER
    tar xf iw-$IW_VER.tar.xz
    cd iw-$IW_VER

    # Point pkg-config exclusively at our cross-built libnl, or it would find the
    # host's and produce x86 link flags.
    export PKG_CONFIG_LIBDIR=$OUT/lib/pkgconfig
    export PKG_CONFIG_PATH=$OUT/lib/pkgconfig

    # LIBS is seeded on the command line so the Makefile's "override LIBS +="
    # appends to it: static libnl-3.a needs pthread_rwlock_*, and a static
    # archive carries no dependency information of its own.
    make -j$(nproc) CC=${CROSS_COMPILE}gcc \
                    AR=${CROSS_COMPILE}ar \
                    LIBS="-lpthread -lm" \
                    LDFLAGS="-L$OUT/lib" \
        || { echo "iw build failed" >&2; exit 1; }

    cp iw $OUT/bin/
    ${CROSS_COMPILE}strip $OUT/bin/iw 2>/dev/null || true
    echo "iw installed"
else
    echo "=== [3/3] iw already built ==="
fi

echo ""
echo "=== apfpv build complete ==="
file $OUT/bin/* | cut -c1-110
echo ""
echo "Re-run ./build-sdk.sh to stage these into the initramfs."
