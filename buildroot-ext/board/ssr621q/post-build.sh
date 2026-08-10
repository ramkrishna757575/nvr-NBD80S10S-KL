#!/bin/sh
#
# Post-build fixups for the ground station.
#
# $1 is buildroot's target directory.
#
# This runs on every image build, which is the point: a package's install step
# is stamped and will not re-run once the package is built, so anything done
# there can silently go missing from a rebuilt image.
set -e

TARGET=$1
FBDEV=$TARGET/config/fbdev.ini

# The OSD window ships as ARGB1555 (format 6), whose single alpha bit makes a
# pixel either fully opaque or absent -- no translucent panel, no anti-aliased
# edge. ARGB4444 (format 2) is the same 16bpp, so the buffer size is unchanged,
# and trades colour depth no status text will miss for 16 levels of alpha.
#
# Patched here rather than in vendor/, which is checksummed by fetch-deps.sh and
# has to stay as it shipped.
[ -f "$FBDEV" ] || { echo "post-build: no $FBDEV" >&2; exit 1; }

sed -i 's/^FB_HWWIN_FORMAT = 6$/FB_HWWIN_FORMAT = 2/' "$FBDEV"

grep -q '^FB_HWWIN_FORMAT = 2$' "$FBDEV" || {
	echo "post-build: fbdev.ini still not ARGB4444" >&2
	exit 1
}
