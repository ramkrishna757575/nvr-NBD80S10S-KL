#!/bin/bash
# Fetch the public prerequisites build-buildroot.sh expects to find under build/.
#
# Everything here is downloadable. What it CANNOT fetch is build/vendor/ --
# the XiongMai kernel modules, /config panel timings and libraries lifted from
# the stock firmware. Those are proprietary and are not redistributed here, so
# a machine without them can build the kernel but not a working image (the 'xm'
# module set is the only one that both decodes and drives HDMI).
#
# Idempotent: re-running skips anything already present.
set -e

SCRIPT_DIR=$(dirname "$(realpath "$0")")
BUILD_DIR=$SCRIPT_DIR/build
mkdir -p "$BUILD_DIR"

# Pinned so a build is reproducible.
SDK_REPO=https://github.com/wireless-tag-com/openwrt-ssd20x.git
RTL_REPO=https://github.com/svpcom/rtl8812au.git
# Pinned so an upstream change cannot break this build without someone choosing
# it. Both are cloned at a fixed commit rather than a branch tip.
SDK_REF=0462db78958d11cb937e662f56a93cdf30b92a59
RTL_REF=20bcaf511f159bfd8f435f7117b82056fc453572
TOOLCHAIN_URL=https://toolchains.bootlin.com/downloads/releases/toolchains/armv7-eabihf/tarballs/armv7-eabihf--glibc--stable-2018.11-1.tar.bz2
TOOLCHAIN_DIR=armv7-eabihf--glibc--stable-2018.11-1

# ── python shim ──────────────────────────────────────────────────────────────
# SigmaStar's kernel Makefile invokes "python", which no longer exists on modern
# distros. build-buildroot.sh puts this directory first on PATH.
if [ ! -e "$BUILD_DIR/shim/python" ]; then
    echo "=== python shim ==="
    mkdir -p "$BUILD_DIR/shim"
    ln -sf "$(command -v python3)" "$BUILD_DIR/shim/python"
fi

# ── SigmaStar SDK (kernel 4.9.84 + MI userspace) ─────────────────────────────
if [ ! -d "$BUILD_DIR/sdk/sigmastar/kernel/4.9.84" ]; then
    echo "=== SigmaStar SDK (large, several minutes) ==="
    git clone --filter=blob:none --no-checkout "$SDK_REPO" "$BUILD_DIR/sdk"
    git -C "$BUILD_DIR/sdk" checkout -q "$SDK_REF"
else
    echo "=== SigmaStar SDK present ==="
fi

# ── Buildroot toolchain, gcc 7.3.0 / glibc 2.27 ──────────────────────────────
# A modern gcc cannot build a 4.9 kernel, so the version matters.
if [ ! -d "$BUILD_DIR/toolchain/$TOOLCHAIN_DIR" ]; then
    echo "=== Buildroot ARM toolchain ==="
    mkdir -p "$BUILD_DIR/toolchain"
    wget -q --show-progress -O /tmp/toolchain.tar.bz2 "$TOOLCHAIN_URL"
    tar -xjf /tmp/toolchain.tar.bz2 -C "$BUILD_DIR/toolchain"
    rm -f /tmp/toolchain.tar.bz2
else
    echo "=== toolchain present ==="
fi

# ── RTL8812AU (wfb-ng fork) source ───────────────────────────────────────────
# Only the source; the rtl8812au buildroot package builds it against the kernel.
if [ ! -d "$BUILD_DIR/rtl8812au" ]; then
    echo "=== RTL8812AU driver source ==="
    git clone --filter=blob:none --no-checkout "$RTL_REPO" "$BUILD_DIR/rtl8812au"
    git -C "$BUILD_DIR/rtl8812au" checkout -q "$RTL_REF"
else
    echo "=== RTL8812AU present ==="
fi


# ── Vendor blobs, extracted from a stock flash dump ──────────────────────────
# The XiongMai modules, /config panel timing tables and libraries are not
# redistributed here. They are carved out of a 16MB dump of the board's own
# flash, which you need anyway as a recovery image before flashing anything.
#
# Layout from the stock bootargs:
#   mtdparts=nor0:0x10000(ipl),0x40000(boot),0x3F0000(romfs),0x6D0000(usr),
#            0x190000(web),0x2C0000(custom),0x20000(logo),0x80000(mtd)
# The kernel modules live inside usr as lib/modules.tar.lzma, which is why
# they are invisible to a plain search of the extracted squashfs trees.
STOCK_DUMP=${1:-${VENDOR_DUMP:-$SCRIPT_DIR/NBD80S10S-KL_original.bin}}

# The dump can also live in a separate private repository, which is the tidy way
# to keep proprietary XiongMai content out of this public one while still having
# a reproducible build. Point VENDOR_REPO at it:
#
#   VENDOR_REPO=git@github.com:you/nvr-vendor.git ./fetch-deps.sh
#
# or persist it in .vendor-repo (gitignored) so plain ./fetch-deps.sh works:
#
#   echo 'git@github.com:you/nvr-vendor.git' > .vendor-repo
#
# The repo needs only the 16MB dump at its top level -- everything else is
# derived from it below, so there is no second copy to keep in sync.
[ -n "$VENDOR_REPO" ] || VENDOR_REPO=$(cat "$SCRIPT_DIR/.vendor-repo" 2>/dev/null || true)

# The blobs this build needs are committed under vendor/, so a plain clone is
# enough and nothing below has to run. Extracting from a dump is still offered
# for anyone who would rather trust their own board than the committed copies.
if [ -d "$SCRIPT_DIR/vendor/modules" ] && [ ! -f "$STOCK_DUMP" ] \
   && [ ! -d "$BUILD_DIR/vendor/x_modules/modules" ]; then
    echo "=== vendor blobs: using the copies committed in vendor/ ==="
    # Fatal, not a warning: MD5SUMS now lists every vendored file, so a mismatch
    # means one is missing or altered. A .gitignore rule had already dropped the
    # video decoder firmware from the repo without anything noticing.
    if ! (cd "$SCRIPT_DIR/vendor" && md5sum -c MD5SUMS >/dev/null 2>&1); then
        echo "error: vendor/ does not match MD5SUMS -- these differ:" >&2
        (cd "$SCRIPT_DIR/vendor" && md5sum -c MD5SUMS 2>&1 | grep -v ': OK$') >&2
        exit 1
    fi
    echo "  checksums OK ($(wc -l < "$SCRIPT_DIR/vendor/MD5SUMS") files)"
    echo ""
    echo "ready: run ./build-buildroot.sh"
    exit 0
fi

if [ ! -f "$STOCK_DUMP" ] && [ ! -d "$BUILD_DIR/vendor/x_modules/modules" ] \
   && [ -n "$VENDOR_REPO" ]; then
    VENDOR_SRC=$BUILD_DIR/vendor-src
    if [ -d "$VENDOR_SRC/.git" ]; then
        echo "=== updating vendor repo ==="
        git -C "$VENDOR_SRC" pull --ff-only || echo "warning: vendor pull failed" >&2
    else
        echo "=== cloning vendor repo ==="
        mkdir -p "$BUILD_DIR"
        git clone --depth 1 "$VENDOR_REPO" "$VENDOR_SRC"
    fi
    # Take whichever dump it holds rather than requiring an exact filename --
    # a board-specific name is more useful than a generic one in that repo.
    found=$(find "$VENDOR_SRC" -maxdepth 2 -name '*.bin' -size +15M -size -17M 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        STOCK_DUMP=$found
        echo "  using $(basename "$found")"
    else
        echo "warning: no 16MB .bin found in $VENDOR_REPO" >&2
    fi
fi

if [ -d "$BUILD_DIR/vendor/x_modules/modules" ]; then
    echo "=== vendor blobs present ==="
elif [ -f "$STOCK_DUMP" ]; then
    echo "=== extracting vendor blobs from $(basename "$STOCK_DUMP") ==="
    for t in unsquashfs xz; do
        command -v $t >/dev/null || { echo "need $t (apt install squashfs-tools xz-utils)" >&2; exit 1; }
    done
    mkdir -p "$BUILD_DIR/vendor"

    # Carve each squashfs using bytes_used from its own superblock, so the
    # partition padding is never included.
    python3 - "$STOCK_DUMP" "$BUILD_DIR/vendor" <<'PY'
import struct, sys
dump, out = sys.argv[1], sys.argv[2]
d = open(dump, 'rb').read()
if len(d) != 0x1000000:
    print(f"warning: expected a 16MB dump, got {len(d)} bytes")
for name, off in (('romfs', 0x50000), ('usr', 0x440000), ('web', 0xb10000),
                  ('custom', 0xca0000), ('logo', 0xf60000)):
    magic, = struct.unpack_from('<I', d, off)
    if magic != 0x73717368:
        print(f"  {name}: no squashfs at 0x{off:x}, skipping")
        continue
    used, = struct.unpack_from('<Q', d, off + 40)
    open(f"{out}/{name}.sqfs", 'wb').write(d[off:off + used])
    print(f"  {name:<7} 0x{off:07x}  {used} bytes")
PY

    for p in romfs usr; do
        [ -f "$BUILD_DIR/vendor/$p.sqfs" ] || continue
        rm -rf "${BUILD_DIR:?}/vendor/$p"
        unsquashfs -q -d "$BUILD_DIR/vendor/$p" "$BUILD_DIR/vendor/$p.sqfs" >/dev/null
    done

    # modules.tar.lzma -> x_modules/, App.tar.lzma -> x_app/
    if [ -f "$BUILD_DIR/vendor/usr/lib/modules.tar.lzma" ]; then
        mkdir -p "$BUILD_DIR/vendor/x_modules"
        xz --format=lzma -dc "$BUILD_DIR/vendor/usr/lib/modules.tar.lzma" |
            tar -x -C "$BUILD_DIR/vendor/x_modules"
    fi
    if [ -f "$BUILD_DIR/vendor/usr/bin/App.tar.lzma" ]; then
        mkdir -p "$BUILD_DIR/vendor/x_app"
        xz --format=lzma -dc "$BUILD_DIR/vendor/usr/bin/App.tar.lzma" |
            tar -x -C "$BUILD_DIR/vendor/x_app"
    fi
    echo "  extracted $(find "$BUILD_DIR/vendor/x_modules" -name '*.ko' 2>/dev/null | wc -l) kernel modules"
fi

# ── Report on what is still missing ──────────────────────────────────────────
echo ""
if [ -d "$BUILD_DIR/vendor/x_modules/modules" ]; then
    echo "vendor blobs: present ($(ls "$BUILD_DIR"/vendor/x_modules/modules/*.ko 2>/dev/null | wc -l) modules)"
    echo "ready: run ./build-buildroot.sh"
else
    echo "vendor blobs: MISSING"
    echo ""
    echo "  Put a 16MB dump of the board's flash at:"
    echo "    $STOCK_DUMP"
    echo "  or pass its path:  ./fetch-deps.sh /path/to/dump.bin"
    echo ""
    echo "  Or keep it in a private repo and point this script at it:"
    echo "    echo 'git@github.com:you/nvr-vendor.git' > .vendor-repo"
    echo "    ./fetch-deps.sh"
    echo ""
    echo "  Read one off the board from U-Boot:"
    echo "    sf probe 0; sf read 0x21000000 0 0x1000000"
    echo "  then transfer it, or from a running Linux with the whole chip"
    echo "  exposed (mtdparts=NOR_FLASH:16m(whole)):"
    echo "    nc <pc> 1234 < /dev/mtd0"
    echo ""
    echo "  Without it the kernel still builds, but the image has no working MI"
    echo "  stack: no decode and no HDMI."
fi
