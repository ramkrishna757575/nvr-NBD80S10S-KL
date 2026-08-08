#!/usr/bin/env bash
# Build an IPL_CUST-compatible U-Boot image for the NBD80S10S-KL.
# This script only creates artifacts. Flashing U-Boot is deliberately manual.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR="$SCRIPT_DIR/build"
SOURCE_DIR="$BUILD_DIR/uboot-src"
OUTPUT_DIR="$SCRIPT_DIR/output/uboot"
PATCH="$SCRIPT_DIR/patches/0004-uboot-sigmastar-build-for-infinity2m.patch"
TOOLCHAIN_DIR="$BUILD_DIR/toolchain/gcc-arm-8.2-2018.08-x86_64-arm-linux-gnueabihf"
CROSS_COMPILE=arm-linux-gnueabihf-
JOBS=${JOBS:-$(nproc)}
SLOT_SIZE=$((192 * 1024))

die() {
    echo "error: $*" >&2
    exit 1
}

[ -d "$SOURCE_DIR" ] || die "missing $SOURCE_DIR; run fetch-deps.sh first"
[ -x "$TOOLCHAIN_DIR/bin/${CROSS_COMPILE}gcc" ] || \
    die "missing ARM GCC in $TOOLCHAIN_DIR"
[ -f "$PATCH" ] || die "missing $PATCH"

export PATH="$TOOLCHAIN_DIR/bin:$PATH"
export ARCH=arm
export CROSS_COMPILE

if ! grep -q '#include <configs/sstar-common.h>' "$SOURCE_DIR/include/configs/infinity2m.h"; then
    echo "=== Applying Infinity2M port patch ==="
    patch -d "$SOURCE_DIR" -p1 < "$PATCH"
fi

echo "=== Building U-Boot for Infinity2M ==="
make -C "$SOURCE_DIR" distclean
make -C "$SOURCE_DIR" infinity2m_defconfig
# The vendor display, panel, and JPEG boot UI sources do not build for
# Infinity2M. Linux initializes HDMI after boot, so U-Boot does not need them.
sed -i \
    -e 's/^CONFIG_SSTAR_DISP=y$/# CONFIG_SSTAR_DISP is not set/' \
    -e 's/^CONFIG_SSTAR_PNL=y$/# CONFIG_SSTAR_PNL is not set/' \
    -e 's/^CONFIG_SSTAR_JPD=y$/# CONFIG_SSTAR_JPD is not set/' \
    -e 's/^CONFIG_MS_SDMMC=y$/# CONFIG_MS_SDMMC is not set/' \
    "$SOURCE_DIR/.config"
make -C "$SOURCE_DIR" -j"$JOBS"
( cd "$SOURCE_DIR" && ./create_img.sh )

IMAGE="$SOURCE_DIR/u-boot.xz.img.bin"
RAW="$SOURCE_DIR/u-boot.bin"
[ -f "$IMAGE" ] || die "U-Boot packer did not produce $IMAGE"
[ -f "$RAW" ] || die "U-Boot linker did not produce $RAW"

mkdir -p "$OUTPUT_DIR"
cp "$RAW" "$OUTPUT_DIR/u-boot.bin"
cp "$IMAGE" "$OUTPUT_DIR/u-boot.xz.img.bin"

python3 - "$IMAGE" "$RAW" "$OUTPUT_DIR/u-boot-slot.bin" "$SLOT_SIZE" <<'PY'
import lzma
import pathlib
import struct
import sys
import zlib

image_path, raw_path, slot_path, slot_size = sys.argv[1:]
slot_size = int(slot_size)
image = pathlib.Path(image_path).read_bytes()
raw = pathlib.Path(raw_path).read_bytes()

if len(image) < 64:
    raise SystemExit("error: U-Boot image is shorter than its uImage header")
header = bytearray(image[:64])
magic, header_crc, _, size, load, entry, data_crc, os_id, arch, image_type, comp = struct.unpack(
    ">7I4B", header[:32]
)
if magic != 0x27051956:
    raise SystemExit("error: packed U-Boot is not a uImage")
header[4:8] = b"\0" * 4
if zlib.crc32(header) & 0xFFFFFFFF != header_crc:
    raise SystemExit("error: U-Boot uImage header CRC is invalid")
payload = image[64:64 + size]
if len(payload) != size or zlib.crc32(payload) & 0xFFFFFFFF != data_crc:
    raise SystemExit("error: U-Boot uImage payload CRC is invalid")
if payload[:6] != b"\xfd7zXZ\x00":
    raise SystemExit("error: U-Boot payload is not XZ")
if lzma.decompress(payload) != raw:
    raise SystemExit("error: packed U-Boot does not decompress to u-boot.bin")
if len(image) != 64 + size:
    raise SystemExit("error: packed U-Boot has unexpected trailing data")
if len(image) > slot_size:
    raise SystemExit(f"error: {len(image)}-byte image exceeds {slot_size}-byte U-Boot slot")

pathlib.Path(slot_path).write_bytes(image + b"\xff" * (slot_size - len(image)))
print(f"uImage: {len(image)} bytes; raw: {len(raw)} bytes")
print(f"load/entry: 0x{load:08x}/0x{entry:08x}; os/arch/type/comp: {os_id}/{arch}/{image_type}/{comp}")
print(f"slot: {slot_size - len(image)} bytes free; padded image: {slot_path}")
PY

sha256sum "$OUTPUT_DIR"/u-boot.bin "$OUTPUT_DIR"/u-boot.xz.img.bin \
    "$OUTPUT_DIR"/u-boot-slot.bin > "$OUTPUT_DIR/SHA256SUMS"

echo
echo "=== U-Boot build complete ==="
echo "  $OUTPUT_DIR/u-boot.xz.img.bin  direct U-Boot SPI payload"
echo "  $OUTPUT_DIR/u-boot-slot.bin    192 KiB image for flashcp"
echo "  $OUTPUT_DIR/SHA256SUMS"
echo
echo "Do not flash this automatically. It replaces the bootloader at 0x10000."