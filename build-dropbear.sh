#!/bin/bash
#
# Cross-compile Dropbear SSH for the ground station.
#
# telnetd is the only interactive console this board has (UART RX is dead under
# Linux), and it is both unauthenticated and unencrypted. Dropbear replaces it
# for day-to-day work: it is ~200KB as a MULTI binary, needs no separate crypto
# library, and brings scp along so files can be pushed without a TFTP round trip.
#
# Two passes are built:
#
#   1. a native (x86) dropbearkey, used at image-build time to generate the host
#      keys, and
#   2. the ARM binaries that actually ship.
#
# The native pass exists because the whole rootfs is a RAM initramfs -- there is
# no writable persistent storage on this board, so keys generated on the target
# would be different after every reboot and every ssh would trip the "REMOTE HOST
# IDENTIFICATION HAS CHANGED" warning. Generating them once at build time and
# baking them into the image gives a stable identity.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR=$SCRIPT_DIR/build
OUT=$BUILD_DIR/dropbear-out
SRC=$BUILD_DIR/dropbear-src

TOOLCHAIN_BIN=$BUILD_DIR/toolchain/armv7-eabihf--glibc--stable-2018.11-1/bin
CROSS_COMPILE=arm-buildroot-linux-gnueabihf-
HOST_TRIPLET=arm-buildroot-linux-gnueabihf

DB_VER=${DB_VER:-2022.83}
DB_TAR=dropbear-$DB_VER.tar.bz2
DB_URL=https://matt.ucc.asn.au/dropbear/releases/$DB_TAR

# Programs shipped on the board. dbclient and scp are worth the few KB in a
# MULTI build: they make it possible to copy a rebuilt binary onto the running
# system instead of reflashing to test a one-line change.
PROGRAMS="dropbear dropbearkey dbclient scp"

export PATH=$TOOLCHAIN_BIN:$BUILD_DIR/shim:$PATH

command -v ${CROSS_COMPILE}gcc >/dev/null || {
    echo "toolchain not found in $TOOLCHAIN_BIN (run ./fetch-deps.sh)" >&2
    exit 1
}

mkdir -p $SRC $OUT/bin $OUT/etc/dropbear

# ── source ────────────────────────────────────────────────────────────────────
cd $SRC
if [ ! -f $DB_TAR ]; then
    echo "=== fetching dropbear $DB_VER ==="
    wget -q $DB_URL || {
        echo "download failed: $DB_URL" >&2
        exit 1
    }
fi

# ── pass 1: native dropbearkey ────────────────────────────────────────────────
# Only used on the build host, so it is configured with the plain system
# compiler and none of the cross settings.
if [ ! -x $OUT/hostbin/dropbearkey ]; then
    echo "=== [1/2] native dropbearkey (for host key generation) ==="
    rm -rf $SRC/native
    mkdir -p $SRC/native
    tar xf $DB_TAR -C $SRC/native --strip-components=1
    cd $SRC/native
    ./configure --disable-zlib --disable-lastlog \
                --disable-utmp --disable-utmpx \
                --disable-wtmp --disable-wtmpx \
                >/dev/null
    make -j"$(nproc)" PROGRAMS="dropbearkey" >/dev/null
    mkdir -p $OUT/hostbin
    cp dropbearkey $OUT/hostbin/
    cd $SRC
fi

# ── pass 2: ARM binaries ──────────────────────────────────────────────────────
echo "=== [2/2] dropbear $DB_VER for $HOST_TRIPLET ==="
rm -rf $SRC/target
mkdir -p $SRC/target
tar xf $DB_TAR -C $SRC/target --strip-components=1
cd $SRC/target

# No zlib in this toolchain's sysroot, and compression buys nothing on a LAN.
# The utmp/wtmp/lastlog machinery is disabled because there is no writable
# /var/log on a RAM rootfs for it to write to.
./configure --host=$HOST_TRIPLET \
            --disable-zlib \
            --disable-lastlog \
            --disable-utmp --disable-utmpx \
            --disable-wtmp --disable-wtmpx \
            --disable-pututline --disable-pututxline \
            CC=${CROSS_COMPILE}gcc \
            >/dev/null

# MULTI=1 links every program into one binary reached through symlinks, which
# is a big saving when four of them share the same crypto code.
make -j"$(nproc)" PROGRAMS="$PROGRAMS" MULTI=1 >/dev/null

${CROSS_COMPILE}strip dropbearmulti
cp dropbearmulti $OUT/bin/

# ── host keys ─────────────────────────────────────────────────────────────────
# Generated once and reused on every rebuild, so the board keeps the same SSH
# identity across reflashes. Delete build/dropbear-out/etc/dropbear to rotate.
for t in rsa ecdsa ed25519; do
    key=$OUT/etc/dropbear/dropbear_${t}_host_key
    if [ ! -f $key ]; then
        echo "generating $t host key"
        $OUT/hostbin/dropbearkey -t $t -f $key >/dev/null 2>&1 \
            || echo "warning: could not generate $t host key" >&2
    fi
done
chmod 600 $OUT/etc/dropbear/* 2>/dev/null || true

echo ""
echo "dropbear $DB_VER built:"
ls -la $OUT/bin/dropbearmulti
echo "host keys: $(ls $OUT/etc/dropbear | tr '\n' ' ')"
echo ""
echo "Now run ./build-sdk.sh -- it stages these into the image."
