#!/bin/sh
#
# Post-image checks for the ground station.
#
# $1 is buildroot's images directory.
#
# The point is to fail here rather than at the flash prompt. sysupgrade makes
# these same checks on the board, but by then the partition is already erased.
set -e

IMAGES=$1
UIMAGE=$IMAGES/uImage

# 11456k@0x50000 from the mtdparts on the kernel command line.
PARTITION=11730944

[ -f "$UIMAGE" ] || { echo "post-image: no uImage in $IMAGES" >&2; exit 1; }

SIZE=$(stat -c %s "$UIMAGE")
MAGIC=$(od -A n -t x1 -N 4 "$UIMAGE" | tr -d ' \n')
LOAD=$(od -A n -t x1 -j 16 -N 4 "$UIMAGE" | tr -d ' \n')
DSIZE=$(od -A n -t x1 -j 12 -N 4 "$UIMAGE" | tr -d ' \n')

[ "$MAGIC" = "27051956" ] ||
	{ echo "post-image: not a uImage (magic $MAGIC)" >&2; exit 1; }
[ "$LOAD" = "20008000" ] ||
	{ echo "post-image: load address $LOAD, not an image for this board" >&2; exit 1; }

# Magic and load address survive truncation; the header's own payload length
# does not.
EXPECT=$((0x$DSIZE + 64))
[ "$SIZE" -eq "$EXPECT" ] ||
	{ echo "post-image: size $SIZE but header says $EXPECT" >&2; exit 1; }

[ "$SIZE" -le "$PARTITION" ] ||
	{ echo "post-image: image $SIZE > partition $PARTITION" >&2; exit 1; }

printf 'post-image: uImage %d bytes, %d spare in the system partition\n' \
	"$SIZE" "$((PARTITION - SIZE))"

# Signing is CI's job, where the key is a secret. Done here too when a local key
# happens to be present, so a hand-built image can be installed without -k.
KEY=${NVR_SIGNING_KEY:-$HOME/.config/nvr-signing/signing.key}
if [ -f "$KEY" ] && command -v openssl >/dev/null 2>&1; then
	openssl dgst -sha256 -binary -out "$IMAGES/.digest" "$UIMAGE"
	openssl pkeyutl -sign -rawin -inkey "$KEY" \
		-in "$IMAGES/.digest" -out "$UIMAGE.sig"
	rm -f "$IMAGES/.digest"
	[ "$(stat -c %s "$UIMAGE.sig")" = "64" ] ||
		{ echo "post-image: signature is not 64 bytes" >&2; exit 1; }
	echo "post-image: signed with $KEY"
else
	echo "post-image: unsigned -- sysupgrade will need -k"
fi
