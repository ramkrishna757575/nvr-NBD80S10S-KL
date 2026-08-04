#!/bin/bash
#
# Cross-compile the wfb-ng receive stack for the SSR621Q ground station.
#
# Kept separate from build-sdk.sh because it fetches from the network and only
# needs re-running when the wfb sources change; build-sdk.sh just stages whatever
# binaries it finds in build/wfb-out.
#
# Produces static-ish binaries in build/wfb-out/bin:
#   wfb_rx     - receives + FEC-decodes + decrypts the drone video stream
#   wfb_tx     - uplink (telemetry / RC back to the drone)
#   wfb_keygen - generates the gs.key / drone.key pair
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR=$SCRIPT_DIR/build
OUT=$BUILD_DIR/wfb-out
SRC=$BUILD_DIR/wfb-src

TOOLCHAIN_BIN=$BUILD_DIR/toolchain/armv7-eabihf--glibc--stable-2018.11-1/bin
CROSS_COMPILE=arm-buildroot-linux-gnueabihf-
HOST_TRIPLET=arm-buildroot-linux-gnueabihf

# Pin versions: wfb-ng master moves, and a silent bump would change the wire
# format against an already-flashed drone.
LIBSODIUM_VER=1.0.19
LIBPCAP_VER=1.10.4
WFB_REF=master

export PATH=$TOOLCHAIN_BIN:$BUILD_DIR/shim:$PATH
export CC=${CROSS_COMPILE}gcc
export AR=${CROSS_COMPILE}ar
export RANLIB=${CROSS_COMPILE}ranlib
export STRIP=${CROSS_COMPILE}strip

# The Buildroot toolchain bundles its own bison/flex whose data directories point
# at /opt/... on the machine that built the toolchain, so once the toolchain is on
# PATH any unprefixed `bison` fails with "m4sugar.m4: cannot open". Shadow them
# with the host copies rather than trying to override YACC/LEX per build system.
HOSTBIN=$BUILD_DIR/hostbin
mkdir -p $HOSTBIN
for t in bison flex m4 yacc lex pkg-config pkgconf; do
    [ -x /usr/bin/$t ] && ln -sf /usr/bin/$t $HOSTBIN/$t
done
export PATH=$HOSTBIN:$PATH

command -v $CC >/dev/null || { echo "toolchain not found in $TOOLCHAIN_BIN"; exit 1; }

mkdir -p $SRC $OUT/bin $OUT/lib $OUT/include

# ── libsodium ─────────────────────────────────────────────────────────────────
if [ ! -f $OUT/lib/libsodium.a ]; then
    echo "=== [1/3] libsodium $LIBSODIUM_VER ==="
    cd $SRC
    [ -f libsodium-$LIBSODIUM_VER.tar.gz ] || \
        wget -q https://download.libsodium.org/libsodium/releases/libsodium-$LIBSODIUM_VER.tar.gz
    # The release tarball unpacks to "libsodium-stable", not a versioned
    # directory, so take the name from the archive instead of assuming.
    sdir=$(tar tf libsodium-$LIBSODIUM_VER.tar.gz | head -1 | cut -d/ -f1)
    rm -rf "$sdir"
    tar xf libsodium-$LIBSODIUM_VER.tar.gz
    cd "$sdir"
    ./configure --host=$HOST_TRIPLET --prefix=$OUT \
                --enable-static --disable-shared --disable-pie >/dev/null
    make -j$(nproc) >/dev/null
    make install >/dev/null
    echo "libsodium installed"
else
    echo "=== [1/3] libsodium already built ==="
fi

# ── libpcap ───────────────────────────────────────────────────────────────────
if [ ! -f $OUT/lib/libpcap.a ]; then
    echo "=== [2/3] libpcap $LIBPCAP_VER ==="
    cd $SRC
    [ -f libpcap-$LIBPCAP_VER.tar.gz ] || \
        wget -q https://www.tcpdump.org/release/libpcap-$LIBPCAP_VER.tar.gz
    rm -rf libpcap-$LIBPCAP_VER
    tar xf libpcap-$LIBPCAP_VER.tar.gz
    cd libpcap-$LIBPCAP_VER
    # without-libnl: we have no libnl for the target and do not need nl80211
    # here, since wifi-monitor already puts the interface into monitor mode.
    #
    # YACC/LEX are pinned to /usr/bin explicitly (not via command -v, which finds
    # the toolchain first): the Buildroot toolchain bundles a bison whose
    # BISON_PKGDATADIR points at /opt/... from the machine it was built on, so it
    # shadows the system bison and dies with "m4sugar.m4: cannot open".
    HOST_BISON=/usr/bin/bison
    HOST_FLEX=/usr/bin/flex
    ./configure --host=$HOST_TRIPLET --prefix=$OUT \
                --with-pcap=linux --without-libnl \
                --disable-shared --disable-dbus --disable-rdma \
                YACC="$HOST_BISON -y" LEX="$HOST_FLEX" >/dev/null
    make -j$(nproc) YACC="$HOST_BISON -y" LEX="$HOST_FLEX" >/dev/null
    make install >/dev/null
    echo "libpcap installed"
else
    echo "=== [2/3] libpcap already built ==="
fi

# ── wfb-ng ────────────────────────────────────────────────────────────────────
echo "=== [3/3] wfb-ng ($WFB_REF) ==="
cd $SRC
if [ ! -d wfb-ng ]; then
    git clone --depth 50 https://github.com/svpcom/wfb-ng.git wfb-ng
fi
cd wfb-ng
git checkout -q $WFB_REF 2>/dev/null || true

# gcc 7.3 (pinned by the kernel modules) rejects designated initializers that
# skip fields -- "sorry, unimplemented: non-trivial designated initializers".
# Only this one site in rx.cpp trips it; zero-init plus assignment is exactly
# what the designated form means. Idempotent so re-runs are safe.
python3 - <<'PY'
import re, sys
p = 'src/rx.cpp'
s = open(p).read()
old = """    wrxfwd_t fwd_hdr = { .wlan_idx = wlan_idx,
                         .freq = htons(freq),
                         .mcs_index = mcs_index,
                         .bandwidth = bandwidth };"""
new = """    /* gcc 7.3 cannot handle designated initializers that skip fields;
       zero-init plus assignment is equivalent. */
    wrxfwd_t fwd_hdr;
    memset(&fwd_hdr, 0, sizeof(fwd_hdr));
    fwd_hdr.wlan_idx = wlan_idx;
    fwd_hdr.freq = htons(freq);
    fwd_hdr.mcs_index = mcs_index;
    fwd_hdr.bandwidth = bandwidth;"""
if old in s:
    open(p, 'w').write(s.replace(old, new))
    print("  patched rx.cpp for gcc 7.3")
elif 'gcc 7.3 cannot handle' in s:
    print("  rx.cpp already patched")
else:
    print("  WARNING: rx.cpp initializer not found -- upstream changed?", file=sys.stderr)
PY

# Drive upstream's own Makefile rather than reimplementing its rules: it knows
# the object lists (rx/radiotap/zfex/wifibroadcast) and the -std flags per
# language. Only the specific C binaries are requested -- `make all` would also
# try to build the Python/Cython service layer and a venv, none of which the
# ground station needs.
#
# ZFEX_USE_INTEL_SSSE3 is dropped from the default flags (x86-only) and NEON is
# kept, which is what matters on the Cortex-A7.
WFB_CFLAGS="-I$OUT/include -Wall -O2 -fno-strict-aliasing \
    -DZFEX_UNROLL_ADDMUL_SIMD=8 -DZFEX_USE_ARM_NEON \
    -DZFEX_INLINE_ADDMUL -DZFEX_INLINE_ADDMUL_SIMD"

make -j$(nproc) wfb_rx wfb_tx wfb_keygen \
    CC=${CROSS_COMPILE}gcc \
    CXX=${CROSS_COMPILE}g++ \
    CFLAGS="$WFB_CFLAGS" \
    LDFLAGS="-L$OUT/lib" \
    || { echo "wfb-ng build failed" >&2; exit 1; }

mkdir -p $OUT/bin
for b in wfb_rx wfb_tx wfb_keygen; do
    [ -f $b ] && cp $b $OUT/bin/
done
${CROSS_COMPILE}strip $OUT/bin/* 2>/dev/null || true

echo ""
echo "=== wfb-ng build complete ==="
file $OUT/bin/* 2>/dev/null | cut -c1-120
echo ""
echo "Re-run ./build-sdk.sh to stage these into the initramfs."
