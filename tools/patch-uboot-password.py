#!/usr/bin/env python3
"""Patch the verified XM_DVR console-password gate in a dumped U-Boot slot."""
import argparse
import lzma
import struct
import sys
import zlib


SLOT_SIZE = 0x30000
HEADER_SIZE = 64
PASSWORD_FN_OFFSET = 0x1098
PASSWORD_FN = bytes.fromhex("10 40 2d e9 02 dc 4d e2")
RETURN_SUCCESS = bytes.fromhex("00 00 a0 e3 1e ff 2f e1")


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="192 KiB U-Boot MTD dump")
    parser.add_argument("output", help="patched 192 KiB U-Boot flash image")
    args = parser.parse_args()

    flash = open(args.input, "rb").read()
    if len(flash) != SLOT_SIZE:
        fail(f"expected a {SLOT_SIZE}-byte U-Boot partition, got {len(flash)}")

    header = bytearray(flash[:HEADER_SIZE])
    try:
        magic, header_crc, timestamp, size, load, entry, data_crc, os_id, arch, image_type, comp = struct.unpack(
            ">7I4B", header[:32]
        )
    except struct.error:
        fail("short U-Boot header")
    if magic != 0x27051956 or size > SLOT_SIZE - HEADER_SIZE:
        fail("not a valid uImage in a 192 KiB U-Boot partition")
    header[4:8] = b"\0" * 4
    if zlib.crc32(header) & 0xFFFFFFFF != header_crc:
        fail("uImage header CRC does not match")

    payload = flash[HEADER_SIZE:HEADER_SIZE + size]
    if zlib.crc32(payload) & 0xFFFFFFFF != data_crc:
        fail("uImage payload CRC does not match")
    try:
        raw = bytearray(lzma.decompress(payload, format=lzma.FORMAT_XZ))
    except lzma.LZMAError as error:
        fail(f"uImage payload is not valid XZ: {error}")

    if b"Password: " not in raw or raw[PASSWORD_FN_OFFSET:PASSWORD_FN_OFFSET + 8] != PASSWORD_FN:
        fail("this is not the verified XM_DVR password-gate build")

    raw[PASSWORD_FN_OFFSET:PASSWORD_FN_OFFSET + 8] = RETURN_SUCCESS
    filters = [{"id": lzma.FILTER_LZMA2, "dict_size": 8 * 1024 * 1024}]
    patched_payload = lzma.compress(
        bytes(raw), format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64, filters=filters
    )
    if HEADER_SIZE + len(patched_payload) > SLOT_SIZE:
        fail(f"patched image is {HEADER_SIZE + len(patched_payload)} bytes, exceeds {SLOT_SIZE}")
    if lzma.decompress(patched_payload, format=lzma.FORMAT_XZ) != raw:
        fail("patched XZ stream did not round-trip")

    header = bytearray(flash[:HEADER_SIZE])
    struct.pack_into(
        ">I", header, 12, len(patched_payload)
    )
    struct.pack_into(
        ">I", header, 24, zlib.crc32(patched_payload) & 0xFFFFFFFF
    )
    header[4:8] = b"\0" * 4
    struct.pack_into(
        ">I", header, 4, zlib.crc32(header) & 0xFFFFFFFF
    )

    output = bytes(header) + patched_payload
    output += b"\xff" * (SLOT_SIZE - len(output))
    open(args.output, "wb").write(output)
    print(f"wrote {args.output}: payload {len(patched_payload)} bytes, {SLOT_SIZE - HEADER_SIZE - len(patched_payload)} bytes free")
    print("password gate: 0x1098 e92d4010 e24ddc02 -> e3a00000 e12fff1e")
    print(f"uImage: os={os_id} arch={arch} type={image_type} comp={comp} load=0x{load:08x} entry=0x{entry:08x} timestamp=0x{timestamp:08x}")


if __name__ == "__main__":
    main()