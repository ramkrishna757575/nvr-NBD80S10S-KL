#!/bin/bash
# Build the SigmaStar SDK 4.9.84 kernel for the NBD80S10S-KL (SSR621Q / Infinity2M).
#
# This is the "vendor stack" firmware track, separate from build.sh (linux-chenxing 6.5).
# It is required for the ground-station use case because hardware video decode (mi_vdec),
# display (mi_disp) and HDMI output (mi_hdmi) only exist as SigmaStar MI modules built
# against this kernel.
set -e

ARCH=arm
JOBS=$(nproc)

SCRIPT_DIR=$(dirname "$(realpath "$0")")
BUILD_DIR=$SCRIPT_DIR/build
OUTPUT_DIR=$SCRIPT_DIR/output

KERNEL_DIR=$BUILD_DIR/sdk/sigmastar/kernel/4.9.84
MPP_DIR=$BUILD_DIR/sdk/18.06/package/sigmastar/sstar-mpp/files/glibc
INITRAMFS_DIR=$BUILD_DIR/initramfs-sdk
INITRAMFS_NODES=$BUILD_DIR/initramfs-sdk.nodes
BUSYBOX_SRC=$BUILD_DIR/busybox
# Built out-of-tree so the linux-chenxing track's build/busybox tree is left alone.
BUSYBOX_BUILD=$BUILD_DIR/busybox-sdk

# Board match: the stock DTB identifies as INFINITY2M_SSC010A-S01A-S, and the board
# boots from NOR (not SPI NAND), so use the plain ssc010a_s01a defconfig.
DEFCONFIG=infinity2m_ssc010a_s01a_defconfig

# gcc 7.3.0 from the bundled Buildroot toolchain. A modern gcc cannot build a 4.9 kernel.
TOOLCHAIN_BIN=$BUILD_DIR/toolchain/armv7-eabihf--glibc--stable-2018.11-1/bin
CROSS_COMPILE=arm-buildroot-linux-gnueabihf-

mkdir -p $OUTPUT_DIR

if [ ! -d $KERNEL_DIR ]; then
    echo "error: SDK kernel not found at $KERNEL_DIR" >&2
    exit 1
fi

# build/shim/python is a symlink to python3, so the kernel Makefile finds a "python".
export PATH=$BUILD_DIR/shim:$TOOLCHAIN_BIN:$PATH
export ARCH CROSS_COMPILE

# ── Python 2 -> 3 fixes for SigmaStar's build helpers ─────────────────────────
# These ship as python2 and break under python3. Applied idempotently so the build
# still works after a fresh clone of the SDK.
echo "=== [1/3] Patching SigmaStar python2 build scripts ==="
DTB_PY=$KERNEL_DIR/scripts/ms_builtin_dtb_update.py
INT_PY=$KERNEL_DIR/scripts/ms_bin_option_update_int.py
MVXV_PY=$KERNEL_DIR/scripts/ms_gen_mvxv_h.py

# mmap.find() needs bytes, and the DTB must be read in binary mode.
sed -i -e "s/^    name='#MS_DTB#'/    name=b'#MS_DTB#'/" \
       -e "s/^    dtb_file=open(sys.argv\[2\])$/    dtb_file=open(sys.argv[2],'rb')/" \
       -e "s/% dtb.size())/% size)/" \
       $DTB_PY

# python3 has no long(), and mmap.find() needs bytes.
sed -i -e "s/^    name=sys.argv\[2\]$/    name=sys.argv[2].encode()/" \
       -e "s/=long(/=int(/g" \
       $INT_PY

# print statements. This one runs from the kernel.release target, so it breaks
# the build before a single object is compiled. Idempotent: a converted line
# starts "print(" and no longer matches.
sed -i -E -e "s/^([[:space:]]*)print[[:space:]]+('.*')$/\1print(\2)/" \
          -e "s/^([[:space:]]*)print[[:space:]]+(\".*\")$/\1print(\2)/" \
          $MVXV_PY

# ── mstar_gpio_* aliases for the stock XM mhal.ko ─────────────────────────────
# The prebuilt XM mhal.ko (the only one with HDMI TX support) links against five
# gpio_chip callbacks that XM's kernel exports as mstar_gpio_*. This kernel has the
# identical functions with identical signatures under the name camdriver_gpio_*,
# already non-static and exported, so aliasing is a rename rather than a guess.
# Without these, XM's mhal cannot load and nothing downstream of it does either.
GPIO_C=$KERNEL_DIR/drivers/sstar/gpio/mdrv_gpio_io.c
if ! grep -q "mstar_gpio_request" $GPIO_C; then
    cat >> $GPIO_C << 'EOF'

/* Aliases so the prebuilt stock XM mhal.ko can resolve its GPIO symbols. */
int mstar_gpio_request(struct gpio_chip *chip, unsigned offset)
{
    return camdriver_gpio_request(chip, offset);
}
EXPORT_SYMBOL(mstar_gpio_request);

int mstar_gpio_get(struct gpio_chip *chip, unsigned offset)
{
    return camdriver_gpio_get(chip, offset);
}
EXPORT_SYMBOL(mstar_gpio_get);

int mstar_gpio_direction_input(struct gpio_chip *chip, unsigned offset)
{
    return camdriver_gpio_direction_input(chip, offset);
}
EXPORT_SYMBOL(mstar_gpio_direction_input);

int mstar_gpio_direction_output(struct gpio_chip *chip, unsigned offset, int value)
{
    return camdriver_gpio_direction_output(chip, offset, value);
}
EXPORT_SYMBOL(mstar_gpio_direction_output);

int mstar_gpio_to_irq(struct gpio_chip *chip, unsigned offset)
{
    return camdriver_gpio_to_irq(chip, offset);
}
EXPORT_SYMBOL(mstar_gpio_to_irq);
EOF
    echo "added mstar_gpio_* aliases to mdrv_gpio_io.c"
fi

# ── MI modules and libraries ──────────────────────────────────────────────────
# Three module sets are staged so they can be compared on the target without a
# rebuild. The SDK and XM builds are two years apart (sdk_commit 677940d /
# 2021-01-14 vs f947025 / 2023-03-31), so they are kept separate rather than mixed
# by default:
#   sdk    - SDK 2021 set. All load, but mhal.ko exports no MhalHdmitx* symbols,
#            so mi_hdmi cannot resolve and there is no HDMI output.
#   xm     - stock XM 2023 set. Self-consistent and has HDMI, but the SDK's glibc
#            libmi_*.so are from the other release and may not match its ioctl ABI.
#   hybrid - SDK set with mhal + mi_hdmi taken from XM, to supply the missing HDMI
#            symbols. Only safe because these modules carry no modversions CRCs.
echo "=== [2/5] Collecting MI modules and libraries ==="
MI_OUT=$OUTPUT_DIR/sdk-mi

# Vendor blobs. Prefer the copies committed to this repo so a plain clone
# builds; fall back to a tree fetch-deps.sh carved out of a flash dump, which is
# what you want if you would rather trust your own board than these files.
if [ -d $SCRIPT_DIR/vendor/modules ]; then
    XM_MODULES=$SCRIPT_DIR/vendor/modules
    XM_CONFIG=$SCRIPT_DIR/vendor/config
    XM_LIB=$SCRIPT_DIR/vendor/lib
    echo "vendor blobs: $SCRIPT_DIR/vendor (committed)"
else
    XM_MODULES=$BUILD_DIR/vendor/x_modules/modules
    XM_CONFIG=$BUILD_DIR/vendor/romfs/config
    XM_LIB=$BUILD_DIR/vendor/romfs/lib
    echo "vendor blobs: $BUILD_DIR/vendor (extracted from a dump)"
fi
XM_FBDEV_INI=$XM_CONFIG/fbdev.ini

rm -rf $MI_OUT
mkdir -p $MI_OUT/modules/sdk $MI_OUT/modules/xm \
         $MI_OUT/lib $MI_OUT/include $MI_OUT/config

MI_MODULE_LIST="mhal mi_common mi_sys mi_gfx mi_divp mi_disp mi_vdec mi_panel mi_hdmi fbdev"

# Which module sets end up in the image. All of them are still BUILT into
# output/sdk-mi for future debugging; this only controls what gets shipped,
# because the image has to fit in 16MB of NOR alongside the bootloader.
# 'xm' is the only set that both decodes and drives HDMI. 'sdk' fails
# MI_SYS_Init outright, and 'alkaid' decodes but cannot set a display timing.
# Override with e.g. MI_SETS="xm alkaid" ./build-sdk.sh when bisecting again.
MI_SETS=${MI_SETS:-xm}

cp $MPP_DIR/modules/4.9.84/*.ko $MI_OUT/modules/sdk/
cp $MPP_DIR/mi_libs/dynamic/*.so $MI_OUT/lib/
cp $MPP_DIR/ex_libs/dynamic/*.so $MI_OUT/lib/ 2>/dev/null || true
cp -r $MPP_DIR/include/* $MI_OUT/include/

if [ -d $XM_MODULES ]; then
    for m in $MI_MODULE_LIST; do
        [ -f $XM_MODULES/$m.ko ] && cp $XM_MODULES/$m.ko $MI_OUT/modules/xm/
    done
    # 'hybrid' (SDK modules + XM mhal/mi_hdmi) and 'xmvdec' (XM set + the SDK's
    # own mi_vdec) were both tried and are dead: hybrid fails MI_SYS_Init with
    # 0xa009201f, xmvdec panics in MI_SYS_IMPL_GetCMDQ because XM's mi_sys has
    # no command queue. Not built any more -- together they cost 12M of
    # initramfs, which is enough to run the board out of memory while the
    # kernel unpacks it.
else
    echo "warning: stock XM modules not found; only the 'sdk' set will be available" >&2
fi

# alkaid: a genuinely version-matched drop -- headers, libraries and modules all
# built together (sdk_commit.ae514f7, 2021-03-02) from one ALKAID release tree,
# for kernel 4.9.84 on Infinity2M NVR. Every other combination we have is
# mismatched: our libs are 341badc (2020-07), the SDK modules 677940d (2021-01),
# XM's 2023 f947025 -- and MI enforces the pairing, which is why the SDK modules
# reject our library outright at MI_SYS_Init. This set gets its own lib and
# include trees so it cannot contaminate the working 'xm' path.
# Source: github.com/industio/PurPle-Pi-R1, project/release/nvr/i2m/common.
# It ships no mi_hdmi: HDMI is driven through MI_DISP device attributes instead.
ALKAID_DIR=$BUILD_DIR/alkaid-sdk
if [ -d $ALKAID_DIR/modules ]; then
    mkdir -p $MI_OUT/modules/alkaid $MI_OUT/lib-alkaid $MI_OUT/include-alkaid
    # Only the modules this pipeline needs, and stripped: these ship with full
    # debug info (mhal.ko alone is 7.6M) and the whole set would push the uImage
    # past 0x23E00000, where U-Boot has relocated itself -- TFTP would overwrite
    # the bootloader mid-transfer and abort.
    for m in $MI_MODULE_LIST; do
        [ -f $ALKAID_DIR/modules/$m.ko ] && cp $ALKAID_DIR/modules/$m.ko $MI_OUT/modules/alkaid/
    done
    cp $ALKAID_DIR/include/*.h  $MI_OUT/include-alkaid/
    for l in libmi_sys libmi_common libmi_disp libmi_divp libmi_vdec \
             libmi_panel libmi_gfx; do
        [ -f $ALKAID_DIR/lib/$l.so ] && cp $ALKAID_DIR/lib/$l.so $MI_OUT/lib-alkaid/
    done
    # The VPU firmware is a file loaded at runtime, not part of mi_vdec.ko, and
    # it is versioned with the driver. Ship this set's own blob alongside its
    # modules; load-mi puts it in place before insmod.
    [ -d $ALKAID_DIR/vdec_fw ] && cp -a $ALKAID_DIR/vdec_fw $MI_OUT/modules/alkaid/
    ${CROSS_COMPILE}strip --strip-debug $MI_OUT/modules/alkaid/*.ko 2>/dev/null || true
    ${CROSS_COMPILE}strip --strip-debug $MI_OUT/lib-alkaid/*.so 2>/dev/null || true
    echo "alkaid: $(ls $MI_OUT/modules/alkaid | wc -l) modules \
($(du -sh $MI_OUT/modules/alkaid | cut -f1)), $(ls $MI_OUT/lib-alkaid | wc -l) libs, \
$(ls $MI_OUT/include-alkaid | wc -l) headers"
fi

# Strip debug info from every module we ship. The SDK and alkaid drops carry
# full debug symbols (the sdk set alone is 16M, mhal.ko 7.6M of it), and the
# initramfs is embedded uncompressed in the kernel's .init section: the kernel
# holds one copy there and writes another into rootfs while unpacking, so
# oversized modules panic the board with "write error" long before they load.
${CROSS_COMPILE}strip --strip-debug $MI_OUT/modules/*/*.ko 2>/dev/null || true

# MI runtime config. mi_sys reads /config/mmap.ini via /config/config_tool, and
# mi_vdec needs the firmware under /config/vdec_fw.
cp -a $MPP_DIR/../config/. $MI_OUT/config/ 2>/dev/null \
    || cp -a $BUILD_DIR/sdk/18.06/package/sigmastar/sstar-mpp/files/config/. $MI_OUT/config/

# fbdev.ko refuses to probe without this; the SDK omits it (panel board), so take
# the stock XM one, which is already configured for 1280x720 over 1080p timing.
[ -f $XM_FBDEV_INI ] && cp $XM_FBDEV_INI $MI_OUT/config/

# Overlay the ENTIRE stock XM /config on top of the SDK one. Cherry-picking files
# is not enough: MI_SYSCFG_GetPanelInfo builds its output-timing table from
# config/panel/DACOUT_*.ini, and without it every timing lookup fails with
# "Not Fund!!!" and MI_DISP_SetPubAttr dies on "Can't find Timing(1080P60)".
# This also brings board.ini, pq/, model/, misc/ and the correct 256MB mmap.ini
# (the SDK's is for the 64MB wireless-tag board: LX 0x3f00000 vs our 0xff00000).
if [ -d $XM_CONFIG ]; then
    cp -a $XM_CONFIG/. $MI_OUT/config/
    # Keep XM's own config_tool. It must match the mi_sys it feeds: the SDK's
    # (glibc) build emits a ~347KB config blob in an older layout, and XM's
    # mi_sys memcpy's that into a smaller buffer -> kernel oops in
    # MI_SYSCFG_ConfigSet <- commonraw_proc_write. XM's config_tool is uClibc,
    # so the uClibc loader is staged into the initramfs further down.
    for l in dump_config dump_mmap load_config load_mmap; do
        ln -sf config_tool $MI_OUT/config/$l
    done
    echo "config: stock XM /config, $(ls $XM_CONFIG/panel | wc -l) panel timings"
fi

# ── BusyBox ───────────────────────────────────────────────────────────────────
# Built here rather than reused from build/busybox: that tree's .config has every
# applet disabled, so its binary has no mount/echo/cat and yields a useless initramfs.
echo "=== [3/5] Building BusyBox ==="
if [ ! -f $BUSYBOX_SRC/Makefile ]; then
    echo "error: busybox source not found at $BUSYBOX_SRC; run ./fetch-deps.sh first" >&2
    exit 1
fi

mkdir -p $BUSYBOX_BUILD
# BusyBox cannot build out-of-tree from a dirty source tree, and build/busybox holds
# the other track's artifacts, so work on a private copy instead of running mrproper
# on a tree this script does not own. Test for a source file rather than Makefile:
# an out-of-tree build leaves behind a stub Makefile that redirects to the original.
if [ ! -d $BUSYBOX_BUILD/libbb ]; then
    cp -a $BUSYBOX_SRC/. $BUSYBOX_BUILD/
    make -C $BUSYBOX_BUILD mrproper
fi

cp $SCRIPT_DIR/config/busybox.config $BUSYBOX_BUILD/.config
# Applets no ground-station script calls: package managers, mail, print and FTP/
# HTTP servers, UBI (this board is NOR), runit, and assorted desk tools. Done
# here rather than in config/busybox.config so the base config stays the stock
# one and this list reads as what it is -- a size cut, not a feature choice.
for a in DPKG DPKG_DEB RPM RPM2CPIO FTPD FTPGET FTPPUT HTTPD SENDMAIL \
         MAKEMIME POPMAILDIR REFORMIME MAN LPD LPQ LPR NBDCLIENT \
         UBIATTACH UBIDETACH UBIMKVOL UBIRENAME UBIRMVOL UBIRSVOL \
         UBIUPDATEVOL BOOTCHARTD POWERTOP LSSCSI MICROCOM RDATE RDEV \
         READPROFILE RTCWAKE RUNSV RUNSVDIR SVLOGD CHPST ENVDIR ENVUIDGID \
         SETUIDGID SOFTLIMIT BEEP HEXEDIT MESG PSTREE PMAP LSOF DC BC; do
    sed -i "s/^CONFIG_$a=y\$/# CONFIG_$a is not set/" $BUSYBOX_BUILD/.config
done
# BusyBox's kconfig has no olddefconfig target; feed oldconfig empty answers so any
# new symbols take their defaults instead of blocking on a prompt.
yes "" | make -C $BUSYBOX_BUILD oldconfig > /dev/null
make -C $BUSYBOX_BUILD -j$JOBS
make -C $BUSYBOX_BUILD install

# A working build has hundreds of applet symlinks; catch a bad config early.
APPLET_COUNT=$(find $BUSYBOX_BUILD/_install -type l | wc -l)
if [ "$APPLET_COUNT" -lt 50 ]; then
    echo "error: busybox produced only $APPLET_COUNT applets -- check config/busybox.config" >&2
    exit 1
fi
echo "busybox: $APPLET_COUNT applets"

# ── Initramfs ─────────────────────────────────────────────────────────────────
echo "=== [4/5] Staging initramfs ==="

rm -rf $INITRAMFS_DIR
mkdir -p $INITRAMFS_DIR/{dev,dev/pts,proc,sys,tmp,root,lib/modules,usr/lib,config}
# /var/run is needed by wpa_supplicant for its control socket; without it the
# daemon exits with "Failed to initialize control interface" even though the
# nl80211 driver bound correctly.
mkdir -p $INITRAMFS_DIR/var/run $INITRAMFS_DIR/var/lock $INITRAMFS_DIR/var/log

cp -a $BUSYBOX_BUILD/_install/* $INITRAMFS_DIR/

for s in $MI_SETS; do
    [ -d $MI_OUT/modules/$s ] || { echo "warning: no module set '$s'" >&2; continue; }
    mkdir -p $INITRAMFS_DIR/lib/modules/$s
    cp -a $MI_OUT/modules/$s/. $INITRAMFS_DIR/lib/modules/$s/
done
echo "modules: shipping set(s) '$MI_SETS' ($(du -sh $INITRAMFS_DIR/lib/modules | cut -f1))"
# Only the libraries mi-player and mi-disp-init actually link. The MPP drop also
# carries audio (libmi_ai/ao + the AEC/AED/APC/BF/SRC/SSL codecs), encode, IPU,
# SED and wlan -- about 1.1M this ground station never opens. Checked rather than
# assumed: none of the five below has a NEEDED or dlopen() on the others.
for l in libmi_sys libmi_common libmi_disp libmi_divp libmi_vdec; do
    cp $MI_OUT/lib/$l.so $INITRAMFS_DIR/usr/lib/ \
        || { echo "error: $l.so missing from the MI drop" >&2; exit 1; }
done
# The alkaid libraries live apart from the 2020 ones -- same sonames, different
# ABI -- and mi-player-alkaid finds them via its rpath.
if [ -d $MI_OUT/lib-alkaid ] && echo "$MI_SETS" | grep -qw alkaid; then
    mkdir -p $INITRAMFS_DIR/usr/lib/alkaid
    cp $MI_OUT/lib-alkaid/*.so $INITRAMFS_DIR/usr/lib/alkaid/
fi
cp -a $MI_OUT/config/. $INITRAMFS_DIR/config/
# XM's boot logo, splash images and startup chime. Nothing here displays or plays
# them -- fb-splash draws its own -- and they are 441K. The rest of /config is
# load-bearing (panel timings, mmap.ini, the VPU firmware).
rm -f $INITRAMFS_DIR/config/misc/*.jpg $INITRAMFS_DIR/config/misc/*.mp3

# ── RTL8812AU (wfb-ng fork) ───────────────────────────────────────────────────
# Built further down, once the kernel is configured: an out-of-tree module has to
# match that config, and the cfg80211/USB symbols it needs are forced built-in
# there. Staged into the initramfs before the kernel links it in.

# ── wfb-ng binaries ───────────────────────────────────────────────────────────
# Built separately by ./build-wfb.sh (it fetches libsodium/libpcap/wfb-ng from
# the network); staged here only if present, so build-sdk.sh stays offline.
WFB_BIN=$BUILD_DIR/wfb-out/bin
if [ -d $WFB_BIN ]; then
    for b in wfb_rx wfb_tx wfb_keygen wfb_tun; do
        [ -f $WFB_BIN/$b ] && cp $WFB_BIN/$b $INITRAMFS_DIR/bin/
    done
    echo "wfb-ng: staged $(ls $INITRAMFS_DIR/bin/wfb_* 2>/dev/null | wc -l) binaries"
else
    echo "wfb-ng: not built (run ./build-wfb.sh) -- skipping"
fi

# ── APFPV (wpa_supplicant) ────────────────────────────────────────────────────
# Built by ./build-apfpv.sh. APFPV joins the air unit's AP as a normal station,
# so this is all that is needed beyond BusyBox's udhcpc.
APFPV_BIN=$BUILD_DIR/apfpv-out/bin
if [ -d $APFPV_BIN ]; then
    mkdir -p $INITRAMFS_DIR/usr/sbin
    for b in wpa_supplicant wpa_cli; do
        [ -f $APFPV_BIN/$b ] && cp $APFPV_BIN/$b $INITRAMFS_DIR/sbin/
    done
    # iw is what OpenIPC's sbc-groundstations scripts call (set_power.sh,
    # channel selection, list_wifi_channels), so shipping the standard tool lets
    # their tooling be reused unchanged instead of reimplemented.
    [ -f $APFPV_BIN/iw ] && cp $APFPV_BIN/iw $INITRAMFS_DIR/usr/sbin/
    echo "apfpv: staged wpa_supplicant + wpa_cli + iw"
else
    echo "apfpv: not built (run ./build-apfpv.sh) -- skipping"
fi

# ── Dropbear SSH ──────────────────────────────────────────────────────────────
# Built by ./build-dropbear.sh. SSH is the way in: authenticated, encrypted, and
# it brings scp for pushing a rebuilt binary onto the running system instead of
# reflashing. telnetd is still built, but stays off unless asked for -- it is the
# recovery path when SSH itself is the thing that broke.
DROPBEAR_OUT=$BUILD_DIR/dropbear-out
if [ -x $DROPBEAR_OUT/bin/dropbearmulti ]; then
    mkdir -p $INITRAMFS_DIR/etc/dropbear $INITRAMFS_DIR/root/.ssh \
             $INITRAMFS_DIR/usr/bin $INITRAMFS_DIR/var/run
    cp $DROPBEAR_OUT/bin/dropbearmulti $INITRAMFS_DIR/sbin/
    # dropbearmulti dispatches on argv[0], so each tool is just a symlink.
    ln -sf /sbin/dropbearmulti $INITRAMFS_DIR/sbin/dropbear
    ln -sf /sbin/dropbearmulti $INITRAMFS_DIR/sbin/dropbearkey
    ln -sf /sbin/dropbearmulti $INITRAMFS_DIR/usr/bin/dbclient
    ln -sf /sbin/dropbearmulti $INITRAMFS_DIR/usr/bin/scp
    ln -sf /usr/bin/dbclient   $INITRAMFS_DIR/usr/bin/ssh

    # No host keys are baked in. They are generated on the board's first boot and
    # kept in the flash 'keys' partition, so the image carries no private key and
    # every board gets its own identity -- a baked key is shared by every board
    # flashed from that image, and leaks the moment the image does. Set
    # BAKE_HOST_KEYS=1 for a private build on a board with no keys partition.
    if [ "${BAKE_HOST_KEYS:-0}" = "1" ]; then
        cp $DROPBEAR_OUT/etc/dropbear/dropbear_*_host_key $INITRAMFS_DIR/etc/dropbear/ 2>/dev/null
        chmod 600 $INITRAMFS_DIR/etc/dropbear/* 2>/dev/null || true
        echo "ssh: host keys BAKED INTO THE IMAGE -- do not publish it"
    fi

    # Public key auth, opt-in. Globbing ~/.ssh/id_*.pub by default silently put
    # the builder's own key into every image, which makes a generic build
    # personal without saying so.
    if [ -n "${SSH_PUBKEY:-}" ] && [ -f "$SSH_PUBKEY" ]; then
        cp "$SSH_PUBKEY" $INITRAMFS_DIR/root/.ssh/authorized_keys
        chmod 700 $INITRAMFS_DIR/root/.ssh
        chmod 600 $INITRAMFS_DIR/root/.ssh/authorized_keys
        echo "ssh: authorized_keys from $SSH_PUBKEY"
    else
        echo "ssh: password login only (set SSH_PUBKEY=/path/to/key.pub to add a key)"
    fi

    # Password login. Defaults to the OpenIPC-style well-known password so the
    # board is usable out of the box and matches what the air unit ships with.
    # Override at build time:
    #
    #   ROOT_PASSWORD='secret'   ./build-sdk.sh   # hashed here, SHA-512
    #   ROOT_PW_HASH='$6$...'    ./build-sdk.sh   # pre-hashed
    #
    # This is a documented default, not a hidden one: anyone with the image can
    # read the hash, so treat the wired side as trusted-LAN-only and change it
    # if the board is ever exposed beyond that.
    ROOT_PASSWORD=${ROOT_PASSWORD:-12345678}
    if [ -n "$ROOT_PASSWORD" ] && [ -z "$ROOT_PW_HASH" ]; then
        if command -v openssl >/dev/null 2>&1; then
            ROOT_PW_HASH=$(openssl passwd -6 "$ROOT_PASSWORD")
        elif command -v mkpasswd >/dev/null 2>&1; then
            ROOT_PW_HASH=$(mkpasswd -m sha-512 "$ROOT_PASSWORD")
        else
            echo "ssh: need openssl or mkpasswd to hash ROOT_PASSWORD" >&2
            exit 1
        fi
    fi
    if [ -n "$ROOT_PW_HASH" ]; then
        SSH_PW_LOGIN=1
        if [ "$ROOT_PASSWORD" = "12345678" ]; then
            echo "ssh: password login enabled for root (default 12345678)"
        else
            echo "ssh: password login enabled for root (custom password)"
        fi
    else
        SSH_PW_LOGIN=0
        ROOT_PW_HASH='*'
        if [ -z "$SSH_PUBKEY" ]; then
            echo "ssh: WARNING - no key and no password; SSH will refuse all logins" >&2
            echo "ssh: telnet remains available on the wired interface" >&2
        fi
    fi
    echo "$SSH_PW_LOGIN" > $INITRAMFS_DIR/etc/ssh-password-login
    echo "dropbear: staged ($(stat -c%s $DROPBEAR_OUT/bin/dropbearmulti) bytes, \
$(ls $INITRAMFS_DIR/etc/dropbear | wc -l) host keys)"
else
    echo "dropbear: not built (run ./build-dropbear.sh) -- skipping"
    ROOT_PW_HASH=${ROOT_PW_HASH:-'*'}
fi

# ── accounts ──────────────────────────────────────────────────────────────────
# Dropbear looks root up in /etc/passwd for its shell and home directory and
# refuses the login if the entry is missing, so these are required whether or
# not password auth is in use.
mkdir -p $INITRAMFS_DIR/etc $INITRAMFS_DIR/root
cat > $INITRAMFS_DIR/etc/passwd << EOF
root:x:0:0:root:/root:/bin/sh
EOF
cat > $INITRAMFS_DIR/etc/group << EOF
root:x:0:
EOF
cat > $INITRAMFS_DIR/etc/shadow << EOF
root:$ROOT_PW_HASH:19000:0:99999:7:::
EOF
chmod 600 $INITRAMFS_DIR/etc/shadow
# /bin/sh is BusyBox ash; without this dropbear's shell lookup fails.
echo "/bin/sh" > $INITRAMFS_DIR/etc/shells
# glibc consults this before it will look in /etc/passwd at all. It falls back
# to a compiled-in default when the file is absent, but being explicit costs
# nothing and makes the dependency on libnss_files visible.
cat > $INITRAMFS_DIR/etc/nsswitch.conf << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
EOF
cat > $INITRAMFS_DIR/etc/hosts << 'EOF'
127.0.0.1   localhost
EOF

# ── glibc runtime ─────────────────────────────────────────────────────────────
# BusyBox is static so nothing needed a libc so far, but the MI libraries are
# dynamic. Without the loader the shell reports a bare "not found" for any
# dynamically linked binary, which looks like a missing file.
SYSROOT=$(${CROSS_COMPILE}gcc -print-sysroot)
# libcrypt/libutil are dropbear's: crypt() for password hashes and openpty()
# for the login pty. Missing ones show up only as a bare "not found" at runtime.
#
# libnss_files is subtler and not a NEEDED entry of anything -- glibc dlopen()s
# it by name from getpwnam()/getspnam(). Without it every account lookup fails,
# so dropbear rejects both password AND key logins with a plain "Permission
# denied" and no hint that /etc/passwd was never read.
for f in ld-linux-armhf.so.3 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 \
         librt.so.1 libgcc_s.so.1 libstdc++.so.6 libcrypt.so.1 libutil.so.1 \
         libnss_files.so.2 libnss_dns.so.2 libresolv.so.2; do
    src=$(find $SYSROOT/lib $SYSROOT/usr/lib -maxdepth 1 -name "$f" 2>/dev/null | head -1)
    [ -n "$src" ] && cp -aL "$src" $INITRAMFS_DIR/lib/
done
echo "glibc runtime: $(ls $INITRAMFS_DIR/lib/*.so* 2>/dev/null | wc -l) libraries"

# ── uClibc runtime (for XM's config_tool only) ────────────────────────────────
# config_tool is a stock XM binary linked against /lib/ld-uClibc.so.0 + libc.so.0.
# mi_sys execs it as a usermode helper; if the loader is missing the exec fails
# silently and the config/panel tables are never populated (symptoms:
# "Get LX_MEM fail in mmap ...." and every timing lookup "Not Fund!!!").
# Copy explicitly rather than globbing: XM's /lib also has libc.so.6 pointing at
# uClibc, which would shadow our glibc and break every other binary.
if [ -f $XM_LIB/ld-uClibc-1.0.31.so ]; then
    cp -a $XM_LIB/ld-uClibc-1.0.31.so $XM_LIB/libuClibc-1.0.31.so $INITRAMFS_DIR/lib/
    ln -sf ld-uClibc-1.0.31.so $INITRAMFS_DIR/lib/ld-uClibc.so.1
    ln -sf ld-uClibc.so.1      $INITRAMFS_DIR/lib/ld-uClibc.so.0
    ln -sf libuClibc-1.0.31.so $INITRAMFS_DIR/lib/libc.so.0
    echo "uClibc runtime: staged for config_tool"
fi

# ── MI display init tool ──────────────────────────────────────────────────────
# Built against the SDK's glibc MI libraries. This is what actually creates the
# HDMI transmitter context; without it the TX never starts.
echo "building mi-disp-init"
${CROSS_COMPILE}gcc -O2 -o $INITRAMFS_DIR/bin/mi-disp-init \
    $SCRIPT_DIR/src/mi-disp-init.c \
    -I$MI_OUT/include \
    -L$MI_OUT/lib -lmi_sys -lmi_disp -lmi_common -lpthread -lm -ldl \
    -Wl,-rpath,/usr/lib \
    || echo "warning: mi-disp-init failed to build" >&2

# ── wifi monitor-mode tool ────────────────────────────────────────────────────
# Deliberately dependency-free: the wfb driver implements IW_MODE_MONITOR in its
# wireless-extensions path, so this avoids cross-compiling iw + libnl just to
# switch modes. Also doubles as a sniffer to prove the RF link before wfb-ng.
echo "building wifi-monitor"
${CROSS_COMPILE}gcc -O2 -o $INITRAMFS_DIR/bin/wifi-monitor \
    $SCRIPT_DIR/src/wifi-monitor.c \
    || echo "warning: wifi-monitor failed to build" >&2

# ── framebuffer splash ────────────────────────────────────────────────────────
# MI_DISP only provides a flat background colour; the framebuffer is a separate
# OSD layer on top, so this is what puts anything legible on screen.
echo "building fb-splash"
${CROSS_COMPILE}gcc -O2 -o $INITRAMFS_DIR/bin/fb-splash \
    $SCRIPT_DIR/src/fb-splash.c \
    || echo "warning: fb-splash failed to build" >&2

# ── adaptive link, ground side ────────────────────────────────────────────────
# Scores the downlink from /tmp/wfb.status and tells the air unit, which picks an
# MCS to match. Fatal rather than warned: alink_drone drops to MCS 0 when it
# stops hearing us, so an image missing this is worse on air than one that never
# had it -- the drone would spend the whole flight at its slowest rate.
echo "building alink-gs"
mkdir -p $INITRAMFS_DIR/usr/bin
${CROSS_COMPILE}gcc -O2 -o $INITRAMFS_DIR/usr/bin/alink-gs \
    $SCRIPT_DIR/src/alink-gs.c

echo "building wfb-keyinfo"
${CROSS_COMPILE}gcc -O2 -o $INITRAMFS_DIR/usr/bin/wfb-keyinfo \
    -I$SCRIPT_DIR/src/tweetnacl \
    $SCRIPT_DIR/src/wfb-keyinfo.c $SCRIPT_DIR/src/tweetnacl/tweetnacl.c

# ── firmware signature verification ───────────────────────────────────────────
# sysupgrade fetches over a connection busybox cannot authenticate: its wget
# prints "TLS certificate validation not implemented" and means it. Signing makes
# the transport irrelevant -- an image is installed only if it carries a
# signature from the key below, however it arrived.
#
# Fatal rather than skippable: a verifier that is quietly absent is worse than
# none, because sysupgrade would fall back to trusting the download.
[ -f $SCRIPT_DIR/signing-key.pub ] || {
    echo "error: signing-key.pub missing -- see README, 'Signing images'" >&2
    exit 1
}
[ "$(stat -c%s $SCRIPT_DIR/signing-key.pub)" = "32" ] || {
    echo "error: signing-key.pub must be a raw 32-byte ed25519 public key" >&2
    exit 1
}
python3 -c "import sys; print(','.join('0x%02x' % b for b in open(sys.argv[1],'rb').read()))" \
    $SCRIPT_DIR/signing-key.pub > $BUILD_DIR/signing-pubkey.h
mkdir -p $INITRAMFS_DIR/usr/sbin
echo "building verify-sig"
${CROSS_COMPILE}gcc -O2 -o $INITRAMFS_DIR/usr/sbin/verify-sig \
    -I$SCRIPT_DIR/src/tweetnacl -I$BUILD_DIR \
    $SCRIPT_DIR/src/verify-sig.c $SCRIPT_DIR/src/tweetnacl/tweetnacl.c

# ── video player ──────────────────────────────────────────────────────────────
# UDP/file -> MI_VDEC -> MI_SYS bind -> MI_DISP -> HDMI. Unlike HDMI, VDEC does
# have a shipped library, so only the HDMI half needs raw ioctls.
echo "building mi-player"
# -rdynamic puts the player's own symbols in .dynsym so that libmi_vdec.so binds
# to the ioctl() defined in mi-player.c (which corrects the VDEC ioctl numbering
# mismatch between the 2020 MI libraries and the 2023 XM kernel modules).
${CROSS_COMPILE}gcc -O2 -o $INITRAMFS_DIR/bin/mi-player \
    $SCRIPT_DIR/src/mi-player.c \
    -I$MI_OUT/include \
    -L$MI_OUT/lib -lmi_sys -lmi_disp -lmi_vdec -lmi_divp -lmi_common -lpthread -lm -ldl \
    -rdynamic -Wl,-rpath,/usr/lib \
    || echo "warning: mi-player failed to build" >&2

# Second build against the version-matched alkaid SDK. Same source, different
# headers and libraries, so the two ABIs never meet. The ioctl interposer stays
# inert here: mi-player only shifts VDEC ioctls for the 'xm' set, and this set's
# driver is the exact counterpart of the library it is linked against.
#
# These libraries need glibc 2.28 (fcntl@GLIBC_2.28); the Buildroot toolchain
# the rest of the firmware uses is 2.27. Rather than move everything, build just
# this binary with the ARM GNU 8.2-2018.08 toolchain the SDK was released with
# and give it a private interpreter and rpath under /usr/lib/alkaid, so the
# 2.28 runtime never shadows the 2.27 one the rest of the system links against.
ALKAID_TC=$BUILD_DIR/toolchain/gcc-arm-8.2-2018.08-x86_64-arm-linux-gnueabihf
ALKAID_CC=$ALKAID_TC/bin/arm-linux-gnueabihf-gcc
ALKAID_LIBC=$ALKAID_TC/arm-linux-gnueabihf/libc/lib
if [ -d $MI_OUT/lib-alkaid ] && [ -x $ALKAID_CC ] && \
   echo "$MI_SETS" | grep -qw alkaid; then
    echo "building mi-player-alkaid (gcc 8.2.1 / glibc 2.28)"
    mkdir -p $INITRAMFS_DIR/usr/lib/alkaid
    for l in ld-linux-armhf.so.3 libc.so.6 libm.so.6 libdl.so.2 \
             libpthread.so.0 librt.so.1; do
        cp -a $ALKAID_LIBC/$l $INITRAMFS_DIR/usr/lib/alkaid/ 2>/dev/null
        # the SONAME symlinks point at the versioned files, so take those too
        cp -a $ALKAID_LIBC/$(basename $(readlink -f $ALKAID_LIBC/$l)) \
              $INITRAMFS_DIR/usr/lib/alkaid/ 2>/dev/null || true
    done
    cp -a $ALKAID_TC/arm-linux-gnueabihf/lib/libgcc_s.so.1 \
          $INITRAMFS_DIR/usr/lib/alkaid/ 2>/dev/null || true

    $ALKAID_CC -O2 -o $INITRAMFS_DIR/bin/mi-player-alkaid \
        $SCRIPT_DIR/src/mi-player.c \
        -I$MI_OUT/include-alkaid \
        -L$MI_OUT/lib-alkaid -lmi_sys -lmi_disp -lmi_vdec -lmi_divp -lmi_common \
        -lpthread -lm -ldl \
        -rdynamic \
        -Wl,--dynamic-linker=/usr/lib/alkaid/ld-linux-armhf.so.3 \
        -Wl,-rpath,/usr/lib/alkaid \
        && ${CROSS_COMPILE}strip $INITRAMFS_DIR/bin/mi-player-alkaid \
        || echo "warning: mi-player-alkaid failed to build" >&2
fi

cat > $INITRAMFS_DIR/init << 'EOF'
#!/bin/sh
# The kernel only auto-mounts devtmpfs from prepare_namespace(), which it skips
# when booting an initramfs -- so there is no /dev/console yet and this script
# starts with no stdin/stdout. Mount /dev and attach the console by hand before
# doing anything that needs to print.
/bin/busybox mount -t devtmpfs devtmpfs /dev
exec 0< /dev/console
exec 1> /dev/console
exec 2>&1

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=/usr/lib

/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
# Cap /tmp. It is RAM on this board, and an unbounded writer there (a stream dump,
# a retrying daemon's log) will trigger the OOM killer, which takes telnetd -- the
# only interactive console, since UART RX is dead. A full /tmp must fail writes,
# not cost a power cycle.
/bin/busybox mount -t tmpfs -o size=8m none /tmp
# telnetd allocates a pty per session; without devpts it exits immediately and the
# client sees the connection close as soon as it opens.
mkdir -p /dev/pts
/bin/busybox mount -t devpts devpts /dev/pts

echo ""
echo "============================================="
echo " SigmaStar SDK 4.9.84 on SSR621Q (initramfs) "
echo "============================================="
echo ""

# Loaded on demand rather than at boot: a failure here should drop to a shell
# for debugging instead of panicking.
cat > /bin/load-mi << 'INNER'
#!/bin/sh
# Usage: load-mi [sdk|xm|hybrid] [vdec_debug_level]   (default: sdk, 0)
SET=${1:-sdk}
VDEC_DEBUG=${2:-0}
DIR=/lib/modules/$SET
if [ ! -d $DIR ]; then
    echo "no such module set: $SET (have: $(ls /lib/modules))"
    exit 1
fi
echo "loading MI module set '$SET'"

# Record the set so mi-player knows whether the VDEC ioctl numbers need
# correcting: only XiongMai's 2023 mi_vdec.ko is shifted relative to the
# libmi_vdec.so we link against.
echo "$SET" > /tmp/mi-set

# The VPU firmware is a file, not part of the module: mi_vdec loads
# /config/vdec_fw/normal/chagall.bin during init. /config carries the 2020
# SDK 18.06 blob, so any other module set boots a firmware it was never built
# against. That is not a soft failure -- the decoder accepts the stream, then
# answers every sequence init with SEQERR 0x5000 ("not found sps") and
# consumes zero bytes. Put the set's own firmware in place before insmod.
if [ -d $DIR/vdec_fw ]; then
    cp -a $DIR/vdec_fw/. /config/vdec_fw/
    echo "vdec firmware: using the '$SET' build"
fi

# The MI char devices have no sysfs class, so nothing auto-creates /dev nodes.
# Minors are handed out by a counter in registration order -- exactly how the stock
# XM loader (x_modules/modules/Load_MN63) does it: minor starts at 0 and increments
# for each MI module that inserts successfully. mhal/mi_common/fbdev take no minor.
# The "mi" major does not appear in /proc/devices until mi_common is inserted, so it
# must be looked up lazily rather than before the loop.
MI_MAJOR=""
minor=0
mkdir -p /dev/mi

# Order follows the dependency graph reported by modinfo.
# mi_sys and fbdev need module parameters, as the official SDK init passes them.
for m in mhal mi_common mi_sys mi_gfx mi_divp mi_disp mi_vdec mi_panel mi_hdmi fbdev; do
    [ -f $DIR/$m.ko ] || continue
    case $m in
        mi_sys) ARGS="cmdQBufSize=768 logBufSize=256 default_config_path=/config" ;;
        fbdev)  ARGS="default_config_path_file=/config/fbdev.ini" ;;
        # debug_level is normally 0. Raise it with vdec_debug=N on the kernel
        # command line when the decoder needs to explain itself; it is chatty
        # enough at frame rate to slow the 115200 console down.
        mi_vdec) ARGS="debug_level=$VDEC_DEBUG" ;;
        *)      ARGS="" ;;
    esac
    printf "insmod %-12s" "$m"
    if ! insmod $DIR/$m.ko $ARGS 2>/tmp/insmod.err; then
        echo " FAILED: $(cat /tmp/insmod.err)"
        continue
    fi

    case $m in
        mhal|mi_common|fbdev)
            echo " ok"
            ;;
        *)
            # Node name matches the module; the libraries try /dev/mi/<short> first
            # and fall back to /dev/mi_<short>, so provide both.
            [ -n "$MI_MAJOR" ] || MI_MAJOR=$(awk '$2=="mi" {print $1}' /proc/devices)
            if [ -z "$MI_MAJOR" ]; then
                echo " ok  (no 'mi' major in /proc/devices -- cannot create node!)"
                continue
            fi
            short=${m#mi_}
            mknod /dev/$m c "$MI_MAJOR" $minor 2>/dev/null
            ln -sf ../$m /dev/mi/$short
            echo " ok  -> /dev/$m (c $MI_MAJOR $minor)"
            minor=$((minor + 1))
            ;;
    esac
done

# mi_poll has its own major and is always minor 0.
poll_major=$(awk '$2=="mi_poll" {print $1}' /proc/devices)
if [ -n "$poll_major" ] && [ ! -e /dev/mi_poll ]; then
    mknod /dev/mi_poll c "$poll_major" 0
fi
mdev -s
INNER
chmod +x /bin/load-mi

# Wifi is loaded on demand rather than at boot: the adapter is hot-pluggable and
# keeping it out of the boot path means a driver problem cannot cost us the
# telnet shell, which is the only usable console on this board.
cat > /bin/load-wifi << 'INNER'
#!/bin/sh
DIR=/lib/modules/wifi

# Regulatory domain. Without one the driver runs in the world domain (00),
# which forbids active scanning and transmission on most 5GHz channels: the
# adapter then either sees nothing or catches a stray beacon on a passive scan
# and goes dormant instead of associating. The driver takes an alpha2 directly,
# so this works without CRDA or a regulatory.db.
CC=$(cat /etc/wifi-cc 2>/dev/null)
[ -n "$CC" ] || CC=00

if grep -qE "^(88XXau_wfb|8812eu) " /proc/modules; then
    echo "wifi driver already loaded"
    ip link show wlan0 2>/dev/null || echo "wlan0 did not appear"
    exit 0
fi

# Two chips, two drivers, and the wrong one binds nothing at all. Look the
# adapter up in sysfs and pick: busybox here has no lsusb and there is no
# /proc/bus/usb. Port 3 (Sstar-ehci-3) is the one that enumerates reliably --
# port 2 browns out during enumeration (error -110, repeated power cycles).
# The ids are each driver's own usb_intf.c table.
KO=""
found=""
for d in /sys/bus/usb/devices/*/idVendor; do
    [ -f "$d" ] || continue
    v=$(cat $d)
    p=$(cat ${d%idVendor}idProduct 2>/dev/null)
    case "$v:$p" in
        0bda:a81a|0bda:a82a|0bda:e822)
            KO=$DIR/8812eu.ko; found="$v:$p (8812EU)"; break ;;
        2604:0012|0bda:8812|0bda:881a|2357:0101|0e8d:*)
            KO=$DIR/88XXau_wfb.ko; found="$v:$p (8812AU)"; break ;;
    esac
done

if [ -n "$found" ]; then
    echo "adapter $found"
else
    # An unlisted id is more likely a rebadged AU than a broken board, so try
    # rather than refuse.
    KO=$DIR/88XXau_wfb.ko
    echo "warning: no known adapter id in /sys/bus/usb/devices --"
    echo "         trying 8812AU; if enumeration failed, use the other USB port"
fi

[ -f "$KO" ] || { echo "no $KO"; exit 1; }

# One unknown parameter makes insmod reject the whole module, and not every
# driver build has rtw_country_code.
insmod $KO rtw_country_code=$CC "$@" 2>/dev/null ||
    insmod $KO "$@" ||
    exit 1
echo "$(basename $KO) loaded (regulatory domain $CC)"
# Let the driver finish attaching before anyone touches the interface. The
# 8812AU re-enumerates once on probe, and poking it during that window seems
# to provoke a disconnect/re-enumerate loop.
sleep 5

ip link show wlan0 2>/dev/null || echo "wlan0 did not appear"
INNER
chmod +x /bin/load-wifi

# APFPV: join the air unit's WiFi AP as an ordinary station. Video then arrives
# as plain UDP/RTP over IP -- no monitor mode, no keys, no FEC. This mirrors
# OpenIPC sbc-groundstations' apfpv mode.
#
# Note the DHCP script deliberately does NOT install a default route or touch
# resolv.conf: the drone's AP is not an internet gateway, and letting it become
# the default route breaks the ethernet/telnet path we rely on.
mkdir -p /usr/share/udhcpc
cat > /usr/share/udhcpc/apfpv.script << 'INNER'
#!/bin/sh
case "$1" in
    deconfig)
        ifconfig $interface 0.0.0.0
        fpv-stop
        ;;
    bound|renew)
        # A drone AP handing out 192.168.1.x collides with eth0's static
        # 192.168.1.10: two interfaces in one subnet makes replies leave via the
        # wrong one and kills telnet, which is our only console. Refuse it and
        # say so loudly rather than losing access.
        eth_net=$(ifconfig eth0 2>/dev/null | sed -n 's/.*inet addr:\([0-9]*\.[0-9]*\.[0-9]*\)\..*/\1/p')
        new_net=$(echo "$ip" | cut -d. -f1-3)
        if [ -n "$eth_net" ] && [ "$eth_net" = "$new_net" ]; then
            echo "apfpv: REFUSING $ip -- collides with eth0 subnet $eth_net.0/24" > /dev/console
            echo "apfpv: change the air unit's AP subnet, or boot with apfpv=off" > /dev/console
            ifconfig $interface 0.0.0.0
            exit 0
        fi
        ifconfig $interface $ip netmask ${subnet:-255.255.255.0}
        # Keep the router address: on an AP-mode FPV camera the gateway IS the
        # camera, so it is the first thing to probe for a video stream. We still
        # do not install a default route (that would send eth0 traffic astray).
        echo "${router%% *}" > /tmp/apfpv-gw
        echo "apfpv: $interface = $ip (router ${router:-none}, route not installed)"
        # This is the event we actually care about: the link is now usable.
        fpv-start "${router%% *}"
        ;;
esac
exit 0
INNER
chmod +x /usr/share/udhcpc/apfpv.script

# wpa_cli action script: re-run DHCP every time we (re)associate. Without this
# the link would only get an address on the first association -- so powering the
# drone on later, or power-cycling it, would associate but leave us with no IP.
cat > /usr/share/udhcpc/apfpv-action.sh << 'INNER'
#!/bin/sh
IFACE=$1
EVENT=$2
LOG=/tmp/apfpv.log
# Timestamp with uptime: there is no RTC battery, so wall clock starts at epoch.
T=$(cut -d. -f1 /proc/uptime)
case "$EVENT" in
    CONNECTED)
        echo "[${T}s] apfpv: $IFACE associated, requesting DHCP" >> $LOG
        # By pid file, not killall: eth0 runs its own udhcpc now, and killing
        # that one leaves the management address unrenewed.
        [ -f /var/run/udhcpc.$IFACE.pid ] && kill "$(cat /var/run/udhcpc.$IFACE.pid)" 2>/dev/null
        udhcpc -i $IFACE -s /usr/share/udhcpc/apfpv.script \
               -p /var/run/udhcpc.$IFACE.pid -b -t 10 -A 5 >> $LOG 2>&1
        sleep 2
        ip=$(ifconfig $IFACE | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
        echo "[${T}s] apfpv: $IFACE address ${ip:-none}" >> $LOG
        # Keep the on-screen overlay honest across reconnects.
        sed -i 's/^state=.*/state=COMPLETED/; s/^note=.*/note=/' \
            /tmp/wifi-status 2>/dev/null
        ;;
    DISCONNECTED)
        echo "[${T}s] apfpv: $IFACE disconnected" >> $LOG
        [ -f /var/run/udhcpc.$IFACE.pid ] && kill "$(cat /var/run/udhcpc.$IFACE.pid)" 2>/dev/null
        ifconfig $IFACE 0.0.0.0
        sed -i 's/^state=.*/state=DISCONNECTED/; s/^note=.*/note=LINK LOST/' \
            /tmp/wifi-status 2>/dev/null
        fpv-stop
        ;;
esac
exit 0
INNER
chmod +x /usr/share/udhcpc/apfpv-action.sh

# wfb-ng ground station. Reads /etc/wfb.conf (a symlink onto the persistent
# config partition), puts the adapter in monitor mode on the configured channel,
# and runs wfb_rx. wfb_rx emits plain UDP, which is exactly what mi-player
# already consumes -- the same path proven with the PC sender.
cat > /usr/bin/wfb-start << 'INNER'
#!/bin/sh
CONF=${1:-/etc/wfb.conf}
IFACE=${IFACE:-wlan0}
get() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)\$/\1/p" $CONF 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'; }

CHANNEL=$(get channel);     [ -n "$CHANNEL" ]    || CHANNEL=165
LINK_ID=$(get link_id);     [ -n "$LINK_ID" ]    || LINK_ID=7669206
RADIO_PORT=$(get radio_port); [ -n "$RADIO_PORT" ] || RADIO_PORT=0
UDP_PORT=$(get udp_port);   [ -n "$UDP_PORT" ]   || UDP_PORT=5600
KEY=$(get key);             [ -n "$KEY" ]        || KEY=/mnt/cfg/wfb/gs.key
ALINK=$(get alink);         [ -n "$ALINK" ]      || ALINK=0
ALINK_IP=$(get alink_ip);   [ -n "$ALINK_IP" ]   || ALINK_IP=10.5.0.10
ALINK_PORT=$(get alink_port); [ -n "$ALINK_PORT" ] || ALINK_PORT=9999
ALINK_TUN_NAME=$(get alink_tun_name); [ -n "$ALINK_TUN_NAME" ] || ALINK_TUN_NAME=wfb-gs
ALINK_TUN_ADDR=$(get alink_tun_addr); [ -n "$ALINK_TUN_ADDR" ] || ALINK_TUN_ADDR=10.5.0.1/24
ALINK_TX_PORT=$(get alink_tx_port); [ -n "$ALINK_TX_PORT" ] || ALINK_TX_PORT=5800
ALINK_RX_PORT=$(get alink_rx_port); [ -n "$ALINK_RX_PORT" ] || ALINK_RX_PORT=5801
ALINK_TX_RADIO_PORT=$(get alink_tx_radio_port); [ -n "$ALINK_TX_RADIO_PORT" ] || ALINK_TX_RADIO_PORT=160
ALINK_RX_RADIO_PORT=$(get alink_rx_radio_port); [ -n "$ALINK_RX_RADIO_PORT" ] || ALINK_RX_RADIO_PORT=32
OSD=$(get osd);             [ -n "$OSD" ]        || OSD=1

[ -d /sys/class/net/$IFACE ] || load-wifi || exit 1

# apfpv and wfb cannot share the adapter: one wants managed mode, the other
# monitor. Stop anything holding it.
killall wpa_supplicant 2>/dev/null
[ -f /var/run/udhcpc.$IFACE.pid ] && kill "$(cat /var/run/udhcpc.$IFACE.pid)" 2>/dev/null
sleep 1

if [ ! -f "$KEY" ]; then
    mkdir -p "$(dirname "$KEY")"
    echo "wfb: no key at $KEY, generating a pair"
    ( cd "$(dirname "$KEY")" && wfb_keygen ) || exit 1
    # wfb_keygen writes gs.key and drone.key in the current directory.
    echo "wfb: copy $(dirname "$KEY")/drone.key to the air unit as /etc/drone.key"
fi

# Monitor mode via wireless extensions -- the driver implements IW_MODE_MONITOR
# itself, so no iw or libnl is needed. Order matters: down, mode, up, channel.
# Third argument is the sniff duration; 0 means set the mode and return.
wifi-monitor $IFACE $CHANNEL 0 || {
    echo "wfb: could not put $IFACE into monitor mode on channel $CHANNEL"
    exit 1
}
echo "wfb: $IFACE monitor, channel $CHANNEL, link_id $LINK_ID, port $RADIO_PORT"

echo "$UDP_PORT" > /tmp/wfb.port
# wfb_rx checks /dev/random and libsodium wants entropy, so this can pause on a
# cold boot exactly as dropbearkey does.
#
# Its stdout carries a link report every second, which awk reduces to the current
# values for wfb-cli to read. Rewritten in place rather than appended: /tmp is
# capped at 8m and a stats log would fill it inside a day.
wfb_rx -K "$KEY" -c 127.0.0.1 -u "$UDP_PORT" -p "$RADIO_PORT" -i "$LINK_ID" $IFACE | awk -F'\t' '
BEGIN { rssi="-"; snr="-"; freq="-"; mcs="-"; bw="-"; ants=0 }
# One line per antenna. Report the strongest, which is what a pilot steers by.
$2 == "RX_ANT" {
    split($3, f, ":"); split($5, a, ":")
    if (ants == 0 || a[3] > rssi) { rssi = a[3]; snr = a[6] }
    freq = f[1]; mcs = f[2]; bw = f[3]
    ants++
}
$2 == "PKT" {
    split($3, p, ":")
    printf "%s %s %s %s %s %s %d %s %s %s %d\n",
        freq, mcs, bw, rssi, snr,
        p[1], p[2] * 8 / 1000,
        p[7], p[8], p[3], ants > "/tmp/wfb.status"
    close("/tmp/wfb.status")
    # Stale values would otherwise read as a live link after the signal drops.
    rssi = "-"; snr = "-"; ants = 0
}
' &
echo $! > /tmp/wfb.pid
sleep 2

# Adaptive link reports use the same WFB tunnel pair as OpenIPC: ground TX 160
# reaches the air RX, while air TX 32 reaches this receiver. A single-packet
# FEC block is essential here: control reports are sparse and must not wait for
# a video-sized block to fill.
if [ "$ALINK" = "1" ]; then
    if [ ! -x /bin/wfb_tun ] || [ ! -x /bin/wfb_tx ] || [ ! -x /bin/wfb_rx ] || \
       [ ! -x /usr/bin/alink-gs ] || [ ! -c /dev/net/tun ]; then
        echo "wfb: adaptive link unavailable (missing tunnel, WFB binary, or /dev/net/tun)"
    else
        wfb_tun -t "$ALINK_TUN_NAME" -a "$ALINK_TUN_ADDR" \
                -l "$ALINK_RX_PORT" -u "$ALINK_TX_PORT" &
        echo $! > /tmp/alink-tun.pid
        wfb_tx -K "$KEY" -k 1 -n 1 -u "$ALINK_TX_PORT" \
               -p "$ALINK_TX_RADIO_PORT" -i "$LINK_ID" "$IFACE" &
        echo $! > /tmp/alink-tx.pid
        wfb_rx -K "$KEY" -c 127.0.0.1 -u "$ALINK_RX_PORT" \
               -p "$ALINK_RX_RADIO_PORT" -i "$LINK_ID" "$IFACE" &
        echo $! > /tmp/alink-rx.pid
        sleep 1
        if kill -0 "$(cat /tmp/alink-tun.pid)" 2>/dev/null && \
           kill -0 "$(cat /tmp/alink-tx.pid)" 2>/dev/null && \
           kill -0 "$(cat /tmp/alink-rx.pid)" 2>/dev/null; then
            (
                while :; do
                    alink-gs -i "$ALINK_IP" -p "$ALINK_PORT" &
                    echo $! > /tmp/alink-worker.pid
                    wait "$!"
                    echo "wfb: alink-gs exited; restarting"
                    sleep 1
                done
            ) &
            echo $! > /tmp/alink-supervisor.pid
            echo "wfb: adaptive link tunnel $ALINK_TUN_ADDR, reporting to $ALINK_IP:$ALINK_PORT"
        else
            echo "wfb: adaptive link transport failed to start"
        fi
    fi
fi

# Start the player on a real event, as the apfpv path does with the DHCP lease.
# The event here is wfb_rx decrypting packets. Starting it earlier clears the OSD
# and leaves an empty video plane on screen, which looks like a green screen
# rather than "nothing is arriving".
#
# rssi is the tell: wfb_rx records antenna stats only for packets that decrypted,
# so a value means the link is genuinely carrying video, and a bare packet count
# with no rssi means the key is wrong.
wfb_state() {
    set -- $(cat /tmp/wfb.status 2>/dev/null)
    [ $# -ge 11 ] || { echo none; return; }
    [ "$6" = "0" ] && { echo none; return; }
    [ "$4" = "-" ] && { echo nokey; return; }
    echo up
}
splash() {
    [ -x /bin/fb-splash ] && [ -e /dev/fb0 ] || return 0
    killall fb-splash 2>/dev/null
    fb-splash -p "OPENIPC GROUND STATION" "$1" "$2" >/dev/null 2>&1
}
(
    last=start
    down=0
    while :; do
        now=$(wfb_state)
        if [ "$now" = "up" ]; then
            down=0
            if [ ! -f /tmp/fpv.pid ] || ! kill -0 "$(cat /tmp/fpv.pid)" 2>/dev/null; then
                fpv-start udp
                # After fpv-start, never before: it clears the OSD layer to get
                # the splash off the screen, which would take the overlay too.
                if [ "$OSD" = "1" ] && [ -x /bin/fb-splash ] && [ -e /dev/fb0 ]; then
                    fb-splash --wfb >/dev/null 2>&1 &
                fi
            fi
        else
            # A second without decrypts is normal between keyframes; only give up
            # after several, or the picture would be torn down and rebuilt
            # constantly on a marginal link.
            down=$((down + 1))
            if [ $down -ge 5 ]; then
                if [ -f /tmp/fpv.pid ]; then
                    fpv-stop
                elif [ "$now" != "$last" ]; then
                    case "$now" in
                        nokey) splash "AIR UNIT HEARD, WRONG KEY" \
                                      "copy drone.key to the air unit" ;;
                        *)     splash "WAITING FOR AIR UNIT" \
                                      "channel $CHANNEL  link_id $LINK_ID" ;;
                    esac
                fi
            fi
        fi
        [ $down -ge 5 ] && last=$now
        sleep 2
    done
) &
wait
INNER
chmod +x /usr/bin/wfb-start

cat > /usr/bin/wfb-stop << 'INNER'
#!/bin/sh
# Supervisor before worker: killing the worker while its parent is still in
# wait() only makes the parent start another one.
[ -f /tmp/alink-supervisor.pid ] && kill "$(cat /tmp/alink-supervisor.pid)" 2>/dev/null
[ -f /tmp/alink-worker.pid ] && kill "$(cat /tmp/alink-worker.pid)" 2>/dev/null
killall alink-gs 2>/dev/null
[ -f /tmp/alink-rx.pid ] && kill "$(cat /tmp/alink-rx.pid)" 2>/dev/null
[ -f /tmp/alink-tx.pid ] && kill "$(cat /tmp/alink-tx.pid)" 2>/dev/null
[ -f /tmp/alink-tun.pid ] && kill "$(cat /tmp/alink-tun.pid)" 2>/dev/null
killall wfb_tx wfb_tun 2>/dev/null
rm -f /tmp/alink-worker.pid /tmp/alink-supervisor.pid /tmp/alink-rx.pid \
    /tmp/alink-tx.pid /tmp/alink-tun.pid
[ -f /tmp/wfb.pid ] && kill "$(cat /tmp/wfb.pid)" 2>/dev/null
killall wfb_rx 2>/dev/null
rm -f /tmp/wfb.pid
fpv-stop
INNER
chmod +x /usr/bin/wfb-stop

cat > /usr/bin/wfb-cli << 'INNER'
#!/bin/sh
# Link status, refreshed once a second. -1 prints once and exits.
#
# wfb-ng's own wfb-cli is a Python/twisted ncurses client talking to the
# aggregator service, none of which exists here. It is not needed: wfb_rx prints
# a report on stdout every second, and wfb-start reduces that to the current
# values in /tmp/wfb.status. That file is the only way to reach them -- wfb_rx
# starts at boot and owns the radio, so nothing later can read its stdout. It is
# a single line, rewritten in place, not a growing log.
STATUS=/tmp/wfb.status
ONCE=0
[ "$1" = "-1" ] && ONCE=1

show() {
    if [ ! -f $STATUS ]; then
        echo "wfb-cli: no stats yet -- is wfb-start running? (mode = wfb)"
        return 1
    fi
    if [ -n "$(find $STATUS -mmin +1 2>/dev/null)" ]; then
        echo "wfb-cli: stats are stale, wfb_rx may have exited"
        return 1
    fi
    # Fixed field order from wfb-start's parser; positional to avoid eval.
    set -- $(cat $STATUS)
    [ $# -ge 11 ] || { echo "wfb-cli: short status line"; return 1; }
    if [ "$6" = "0" ]; then
        # A wrong link_id or radio_port is dropped by wfb_rx's capture filter
        # before it counts anything, so it is indistinguishable from silence.
        echo "no signal            wrong channel, or link_id/radio_port mismatch"
    elif [ "$4" = "-" ]; then
        # Past that filter, so link_id and radio_port agree. wfb_rx only records
        # rssi for packets it decrypted, so there is no signal strength to show.
        echo "receiving ${6} pkt/s, none decrypt (decerr ${10}) -- wrong key"
    else
        echo "rssi ${4}dBm  snr ${5}dB   ${6} pkt/s  ${7} kbit/s   fec ${8} lost ${9} decerr ${10}   ${1}MHz mcs${2} bw${3}"
    fi
}

if [ $ONCE -eq 1 ]; then
    show
    exit $?
fi
echo "wfb-cli: ctrl-c to stop"
while :; do
    show
    sleep 1
done
INNER
chmod +x /usr/bin/wfb-cli

# Adapted from OpenIPC sbc-groundstations package/wifibroadcast-ng/files/wfb-nics.
# Theirs greps udevadm output, which we do not have, so the same detection is
# done by walking sysfs for the driver name. The interface is identical, so their
# wifibroadcast scripts can call it unchanged.
mkdir -p /usr/bin
cat > /usr/bin/wfb-nics << 'INNER'
#!/bin/sh
# Print names of RTL8812AU/8812EU/8812CU interfaces, one per line.
for i in /sys/class/net/*; do
    [ -e "$i/device/driver" ] || continue
    drv=$(basename $(readlink -f "$i/device/driver"))
    case "$drv" in
        rtl88xxau_wfb|rtl88x2eu|rtl88x2cu|88XXau*|8812eu*)
            basename "$i"
            ;;
    esac
done
INNER
chmod +x /usr/bin/wfb-nics

# Find the video source on an AP-mode FPV camera. Two very different things get
# called "wifi FPV": some cameras push RTP to a fixed UDP port the moment you
# associate, others emit nothing until an RTSP client asks. mi-player only does
# the former, so this decides whether an RTSP client is needed at all -- and if
# it is, the SDP names the codec and payload type to configure.
cat > /usr/bin/fpv-probe << 'INNER'
#!/bin/sh
# usage: fpv-probe [ip]   (default: the DHCP router, i.e. usually the camera)
TARGET=${1:-$(cat /tmp/apfpv-gw 2>/dev/null)}
if [ -z "$TARGET" ]; then
    ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
    [ -n "$ip" ] && TARGET=$(echo "$ip" | cut -d. -f1-3).1
fi
[ -z "$TARGET" ] && { echo "fpv-probe: no target -- associate first, or pass an IP"; exit 1; }

echo "fpv-probe: target $TARGET"
ping -c 2 -W 2 "$TARGET" 2>&1 | tail -3

echo "fpv-probe: TCP ports"
for p in 554 8554 7070 80 8080 8000 34567; do
    if nc -w 2 "$TARGET" "$p" < /dev/null > /dev/null 2>&1; then
        echo "  $p OPEN"
    fi
done

echo "fpv-probe: RTSP DESCRIBE"
for p in 554 8554 7070; do
    for path in "" live live/ch0 live/ch00_0 11 0 stream0 video1 \
                cam/realmonitor?channel=1
    do
        url="rtsp://$TARGET:$p/$path"
        resp=$(printf 'DESCRIBE %s RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\n\r\n' \
               "$url" | nc -w 3 "$TARGET" "$p" 2>/dev/null)
        [ -z "$resp" ] && continue
        case "$resp" in
            RTSP/1.0\ 200*)
                echo "  OK  $url"
                echo "$resp"
                echo "fpv-probe: RTSP works -- mi-player needs an RTSP client."
                exit 0 ;;
            RTSP*) echo "  $(echo "$resp" | head -1 | tr -d '\r')  $url" ;;
        esac
    done
done

echo "fpv-probe: no RTSP 200. The camera may simply push UDP; watch for it:"
echo "  timeout 10 nc -u -l -p 5600 | od -A x -t x1 -N 64"
echo "(an RTP packet starts 80 60 or 80 e0; Annex-B starts 00 00 00 01)"
INNER
chmod +x /usr/bin/fpv-probe

cat > /usr/bin/fpv-stop << 'INNER'
#!/bin/sh
# Link went away: stop the player and put something on screen, rather than
# leaving the last decoded frame frozen there.
if [ -f /tmp/fpv.pid ]; then
    kill "$(cat /tmp/fpv.pid)" 2>/dev/null
    rm -f /tmp/fpv.pid
fi
rm -f /tmp/fpv.url
killall mi-player mi-player-alkaid 2>/dev/null
echo "fpv: link down, player stopped" > /dev/console
[ -x /bin/fb-splash ] && [ -e /dev/fb0 ] && \
    fb-splash -p "OPENIPC GROUND STATION" \
                 "LINK LOST" \
                 "WAITING FOR AIR UNIT" >/dev/null 2>&1
exit 0
INNER
chmod +x /usr/bin/fpv-stop

cat > /usr/bin/fpv-start << 'INNER'
#!/bin/sh
# Start the player the moment the link is actually usable. This is called from
# the DHCP bound/renew handler, so it runs on a real event instead of after a
# guessed delay -- association plus lease can take anywhere from 5 to 60s
# depending on when the air unit is powered on.
# usage: fpv-start [gateway | udp]
# "udp" is the wfb-ng path: wfb_rx has already put a decoded stream on a local
# UDP port, so there is no RTSP session to negotiate and no config file to wait
# for. Everything downstream -- OSD clearing, retry loop -- is shared.
if [ "$1" = "udp" ]; then
    [ -f /tmp/fpv.conf ] && . /tmp/fpv.conf
    URL="udp:$(cat /tmp/wfb.port 2>/dev/null || echo 5600)"
    # There is no SDP on this path, so nothing announces the format: mi-player
    # would assume H.264 at 1280x720 and decode nothing, which reaches HDMI as a
    # green screen rather than an error. Take both from the config instead.
    wfb_get() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)\$/\1/p" /etc/wfb.conf 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'; }
    CODEC=$(wfb_get codec);      [ -n "$CODEC" ] || CODEC=h265
    [ "$CODEC" = "h265" ] && FPV_OPTS="$FPV_OPTS -h265"
    FPV_SRC=$(wfb_get video_size)
    [ -n "$FPV_SRC" ] || FPV_SRC=1920x1080
else
    [ -f /tmp/fpv.conf ] || exit 0
    . /tmp/fpv.conf
    [ -n "$FPV_URL" ] || exit 0

    GW=${1:-$(cat /tmp/apfpv-gw 2>/dev/null)}
    URL=$FPV_URL
fi
if [ "$URL" = "auto" ]; then
    # On an AP-mode air unit the gateway IS the camera, so there is nothing to
    # hardcode: whatever handed us the lease is what we stream from.
    if [ -z "$GW" ]; then
        echo "fpv: no gateway in the lease, cannot build an RTSP URL" > /dev/console
        exit 1
    fi
    URL="rtsp://${FPV_USER:-root}:${FPV_PASS:-12345}@$GW:554/stream=0"
fi

# Already streaming this URL? Do nothing. udhcpc fires the same bound/renew
# handler on every lease renewal -- and the air unit hands out a short lease --
# so restarting here would tear down and rebuild the whole MI pipeline every
# few seconds, blanking HDMI each time.
if [ -f /tmp/fpv.pid ] && kill -0 "$(cat /tmp/fpv.pid)" 2>/dev/null &&
   [ "$(cat /tmp/fpv.url 2>/dev/null)" = "$URL" ]; then
    exit 0
fi

# Never leave two supervisors running: kill the old one before its child, so it
# cannot restart the player we are about to replace.
if [ -f /tmp/fpv.pid ]; then
    kill "$(cat /tmp/fpv.pid)" 2>/dev/null
    rm -f /tmp/fpv.pid
fi
killall mi-player mi-player-alkaid 2>/dev/null
sleep 1

# The OSD layer sits above the video plane at constant alpha 255, so the splash
# would simply hide the picture. Zero it -- an all-zero ARGB1555 pixel has
# alpha 0, i.e. transparent. mi-disp-init has to go too: it holds /dev/mi_hdmi
# open, and the player brings HDMI up itself.
killall mi-disp-init fb-splash 2>/dev/null
[ -e /dev/fb0 ] && dd if=/dev/zero of=/dev/fb0 bs=64k 2>/dev/null

echo "fpv: link up, streaming $URL" > /dev/console
(
    while :; do
        case "$URL" in
            udp:*) ${FPV_PLAYER:-mi-player} -u "${URL#udp:}" -s "${FPV_SRC:-1280x720}" $FPV_OPTS ;;
            *)     ${FPV_PLAYER:-mi-player} -r "$URL" -s "${FPV_SRC:-1280x720}" $FPV_OPTS ;;
        esac
        # The air unit may still be booting, or may have rebooted mid-flight.
        echo "fpv: player exited, retrying in 3s" > /dev/console
        sleep 3
    done
) > /dev/console 2>&1 &
echo $! > /tmp/fpv.pid
echo "$URL" > /tmp/fpv.url
exit 0
INNER
chmod +x /usr/bin/fpv-start

cat > /bin/apfpv << 'INNER'
#!/bin/sh
# usage: apfpv [ssid] [password] [iface]
SSID=${1:-OpenIPC}
PSK=${2:-12345678}
IFACE=${3:-wlan0}
CONF=/tmp/wpa_apfpv.conf

[ -d /sys/class/net/$IFACE ] || load-wifi || exit 1

# wpa_supplicant needs this for its control socket. The initramfs ships it, but
# create it defensively in case /var was mounted over.
mkdir -p /var/run

# wfb-ng and apfpv are mutually exclusive: one needs monitor mode, the other
# managed. Stop anything holding the interface first -- but only this
# interface's DHCP client, since eth0 has one of its own.
killall wfb_rx wpa_supplicant 2>/dev/null
[ -f /var/run/udhcpc.$IFACE.pid ] && kill "$(cat /var/run/udhcpc.$IFACE.pid)" 2>/dev/null
rm -rf /var/run/wpa_supplicant
sleep 1

cat > $CONF << CONFEOF
ctrl_interface=/var/run/wpa_supplicant
network={
    ssid="$SSID"
    psk="$PSK"
}
CONFEOF

# Back to managed mode only if it is not already there. A freshly loaded driver
# comes up managed, and an unnecessary down/up right after probe is exactly the
# kind of poke that seems to upset it.
mode=$(iw dev $IFACE info 2>/dev/null | awk '/type/{print $2}')
if [ "$mode" != "managed" ]; then
    echo "apfpv: switching $IFACE from '${mode:-unknown}' to managed"
    wifi-monitor $IFACE managed >/dev/null 2>&1
fi
ifconfig $IFACE up

echo "apfpv: joining '$SSID' on $IFACE"
# nl80211 first (what the driver's cfg80211 layer implements); wext is the
# fallback since this driver supports both. Errors go to a log rather than
# /dev/null -- "Cannot open RFKILL control device" is harmless noise, but real
# failures like a missing control-interface directory need to be visible.
if ! wpa_supplicant -B -i $IFACE -c $CONF -D nl80211 >/tmp/wpa.log 2>&1; then
    echo "apfpv: nl80211 failed, trying wext"
    if ! wpa_supplicant -B -i $IFACE -c $CONF -D wext >>/tmp/wpa.log 2>&1; then
        echo "apfpv: wpa_supplicant failed to start:"
        grep -viE "rfkill|DSCP-POLICY" /tmp/wpa.log | tail -8
        exit 1
    fi
fi

# Publish what the overlay needs to explain itself. fb-splash --stats polls
# /tmp/wifi-status once a second; without it the only on-screen symptom of a
# failed join is "dormant", which says nothing about whether the AP was even
# visible or why it refused us.
wifi_status() {
    ST=$(wpa_cli -i $IFACE status 2>/dev/null)
    SS=$(echo "$ST" | sed -n 's/^ssid=//p')
    WS=$(echo "$ST" | sed -n 's/^wpa_state=//p')
    FQ=$(echo "$ST" | sed -n 's/^freq=//p')
    SG=$(iw dev $IFACE link 2>/dev/null | sed -n 's/.*signal: \(-\{0,1\}[0-9]*\).*/\1/p')
    # Not associated: fall back to the scan so we can still say whether the AP
    # is on the air and on which band.
    if [ -z "$SS" ]; then
        SS=$SSID
        SCAN=$(iw dev $IFACE scan 2>/dev/null | awk -v s="$SSID" '
            /freq:/{f=$2} /signal:/{g=$2}
            /SSID: /{ if (substr($0, index($0,": ")+2) == s) { print f, g; exit } }')
        if [ -n "$SCAN" ]; then
            FQ=${SCAN%% *}
            SG=${SCAN##* }
        else
            FQ=""
        fi
    fi
    {
        echo "ssid=$SS"
        echo "freq=$FQ"
        echo "signal=$SG"
        echo "state=${WS:-UNKNOWN}"
        echo "reg=$(cat /etc/wifi-cc 2>/dev/null)"
        echo "note=$1"
    } > /tmp/wifi-status
}

echo "apfpv: waiting for association ..."
n=0
while [ $n -lt 20 ]; do
    wpa_cli -i $IFACE status 2>/dev/null | grep -q "wpa_state=COMPLETED" && break
    n=$((n + 1))
    sleep 1
done

# If it did not come up, say why. wpa_supplicant keeps retrying in the
# background, so this is diagnosis rather than failure -- but without it the
# only symptom is a dormant interface, which says nothing about whether the AP
# was even visible, what band it is on, or whether the key was rejected.
if ! wpa_cli -i $IFACE status 2>/dev/null | grep -q "wpa_state=COMPLETED"; then
    echo "apfpv: not associated after ${n}s. Visible networks:"
    iw dev $IFACE scan 2>/dev/null |
        awk '/^BSS/{bss=$2} /freq:/{f=$2} /signal:/{s=$2} /SSID:/{
              printf "  %-20s %s MHz %s dBm  %s\n", $2, f, s, bss }' |
        head -12
    echo "apfpv: regulatory domain $(cat /etc/wifi-cc 2>/dev/null)"
    echo "apfpv: wpa_state=$(wpa_cli -i $IFACE status 2>/dev/null | sed -n 's/^wpa_state=//p')"
    grep -iE "auth|assoc|reason|WRONG_KEY|4-Way" /tmp/wpa.log 2>/dev/null | tail -5
    echo "apfpv: if the AP is 5GHz, set the regulatory domain: wifi_cc=XX on the"
    echo "apfpv: kernel command line (default 00 blocks most 5GHz channels)"

    # Pick the most specific explanation available for the overlay.
    REASON=$(grep -oiE "WRONG_KEY|4-Way handshake failed|authentication.*timed out|association.*timed out" \
             /tmp/wpa.log 2>/dev/null | tail -1)
    if [ -z "$REASON" ]; then
        if iw dev $IFACE scan 2>/dev/null | grep -q "SSID: $SSID"; then
            REASON="AP SEEN BUT JOIN FAILED"
        else
            REASON="AP NOT FOUND - CHECK BAND/REG"
        fi
    fi
    wifi_status "$REASON"
else
    wifi_status ""
fi

# wpa_supplicant keeps scanning on its own, so a drone that is not powered up yet
# is not an error -- the action script will pick it up whenever it appears.
if wpa_cli -i $IFACE status 2>/dev/null | grep -q "wpa_state=COMPLETED"; then
    echo "apfpv: associated"
else
    echo "apfpv: not associated yet -- will keep retrying in the background"
fi

# DHCP is driven by association events from here on, so powering the drone on
# later or rebooting it re-acquires an address automatically.
killall wpa_cli 2>/dev/null
wpa_cli -i $IFACE -a /usr/share/udhcpc/apfpv-action.sh -B >/dev/null 2>&1

# On-screen counters, so the display shows whether packets are actually arriving.
if [ -x /bin/fb-splash ] && [ -e /dev/fb0 ]; then
    killall fb-splash 2>/dev/null
    fb-splash --stats $IFACE >/dev/null 2>&1 &
    echo "apfpv: on-screen stats started"
fi

sleep 3
ifconfig $IFACE | grep "inet addr" || echo "apfpv: no IP yet"
echo "apfpv: association/DHCP events will be appended to /tmp/apfpv.log"
echo "apfpv: live state -> wpa_cli -i $IFACE status"
INNER
chmod +x /bin/apfpv

# NOTE: there is deliberately no unload-mi. These modules cannot be removed:
# rmmod mhal leaves the mi_log kthread running against freed module text (oops in
# vsnprintf), and re-inserting then dies on a duplicate sysfs 'mpnl' node followed
# by a NULL deref in DrvPnlSysfsInit. Pick the set at boot via mi_set= instead.

# UART RX does not reach userspace on this board (TX works, typed input never
# arrives), so bring up networking and offer an SSH shell as the usable console.
#
# The SDK emac driver has no MAC of its own. Take the board's real address from
# the U-Boot environment, passed on the kernel command line as ethaddr=. The
# bootcmd must build bootargs *inside* setargs -- U-Boot expands ${} only one
# level deep, so a stored bootargs containing ${ethaddr} arrives here verbatim.
# Nothing board-specific is baked into the image; the fallback in
# /etc/fallback-mac is a locally administered address generated at build time
# and only used if U-Boot did not supply one.
MAC=""
ETH_IP=""
for arg in $(cat /proc/cmdline); do
    case $arg in
        ethaddr=*) MAC=${arg#ethaddr=} ;;
        ipaddr=*)  ETH_IP=${arg#ipaddr=} ;;
    esac
done
# U-Boot only expands ${} one level deep, so a bootargs containing the literal
# text "${ethaddr}" reaches us unexpanded. Treat that as "not supplied".
case $MAC in *'$'*|*'{'*) MAC="" ;; esac
if [ -z "$MAC" ]; then
    MAC=$(cat /etc/fallback-mac 2>/dev/null)
    echo "net: no usable ethaddr= on the command line, using fallback $MAC"
    echo "net: to fix, build bootargs inside setargs so \${ethaddr} expands"
fi

# 192.168.1.10 sits inside the DHCP pool of most home routers, so claiming it
# statically means it can also be leased to another device while the board is
# off -- after which telnet reaches the wrong host and the board looks dead.
# So: DHCP by default, and this address only as a fallback for when there is no
# DHCP server at all (a bare switch, or a cable straight to a PC). Pass ipaddr=
# on the kernel command line to force a static address instead.
ETH_FALLBACK_IP=192.168.1.10
ifconfig lo 127.0.0.1 up
[ -n "$MAC" ] && ifconfig eth0 hw ether $MAC
# The router lists this in its client table, which is how you find the board
# once its address is no longer fixed.
hostname nvr-gs

mkdir -p /usr/share/udhcpc
echo "$ETH_FALLBACK_IP" > /tmp/eth-fallback-ip
cat > /usr/share/udhcpc/eth0.script << 'INNER'
#!/bin/sh
case "$1" in
    deconfig)
        ifconfig $interface 0.0.0.0
        ;;
    leasefail|nak)
        fb=$(cat /tmp/eth-fallback-ip 2>/dev/null)
        [ -n "$fb" ] || fb=192.168.1.10
        ifconfig $interface $fb netmask 255.255.255.0 up
        echo "$fb" > /tmp/eth-ip
        echo "net: no DHCP lease on $interface, using fallback $fb" > /dev/console
        ;;
    bound|renew)
        ifconfig $interface $ip netmask ${subnet:-255.255.255.0} up
        echo "$ip" > /tmp/eth-ip
        # Take the default route only if nothing holds it: the drone's AP is not
        # an internet gateway, so eth0 is the sensible owner, but never steal it.
        if [ -n "$router" ] && ! route -n 2>/dev/null | grep -q '^0\.0\.0\.0'; then
            route add default gw ${router%% *} dev $interface 2>/dev/null
        fi
        if [ -n "$dns" ]; then
            : > /etc/resolv.conf
            for s in $dns; do echo "nameserver $s" >> /etc/resolv.conf; done
        fi
        echo "net: $interface $ip  ->  ssh root@$ip" > /dev/console
        ;;
esac
exit 0
INNER
chmod +x /usr/share/udhcpc/eth0.script

# Backgrounded so a missing DHCP server cannot hold up video for the retry
# window. udhcpc daemonises itself once it has a lease; -b makes it do the same
# after giving up, so it keeps retrying behind the fallback address.
eth_dhcp_running() {
    [ -f /var/run/udhcpc.eth0.pid ] || return 1
    kill -0 "$(cat /var/run/udhcpc.eth0.pid)" 2>/dev/null
}

start_eth() {
    if [ -n "$ETH_IP" ]; then
        ifconfig eth0 $ETH_IP netmask 255.255.255.0 up
        echo "$ETH_IP" > /tmp/eth-ip
    else
        ifconfig eth0 0.0.0.0 up
        udhcpc -i eth0 -s /usr/share/udhcpc/eth0.script -x hostname:nvr-gs \
               -p /var/run/udhcpc.eth0.pid -t 4 -T 2 -A 10 -b >/dev/null 2>&1 &
    fi
}
start_eth
# Persistent settings. The rootfs is a RAM initramfs, so this is the only thing
# that survives a reboot -- or a reflash, since it sits above the image. A real
# writable filesystem rather than a hand-rolled blob, so it can be edited over
# SSH with vi and copied to with scp, the way OpenIPC's overlay works.
# Needs mtdparts=NOR_FLASH:11456k@0x50000(system),512k@0xf80000(cfg) on the kernel command line.
CFG_DIR=/mnt/cfg
mount_cfg() {
    mkdir -p $CFG_DIR
    m=$(awk -F'[:"]' '/"cfg"/{print $1}' /proc/mtd 2>/dev/null | head -1)
    [ -n "$m" ] || return 1
    n=${m#mtd}
    mount -t jffs2 /dev/mtdblock$n $CFG_DIR 2>/dev/null && return 0
    # Unformatted on first boot: an erased NOR partition is not a filesystem.
    echo "cfg: formatting /dev/$m (first boot, takes a moment)"
    flash_eraseall -j /dev/$m >/dev/null 2>&1
    mount -t jffs2 /dev/mtdblock$n $CFG_DIR 2>/dev/null
}
if mount_cfg; then
    echo "cfg: $CFG_DIR mounted -- settings here survive reboot and reflash"
    # Seed the config on first boot, then expose it at the conventional path.
    if [ ! -f $CFG_DIR/wfb.conf ]; then
        cat > $CFG_DIR/wfb.conf << 'WFBCONF'
# Ground station link settings.
#
# Edit over SSH and reboot for the change to take effect:
#   ssh root@<board>  ;  vi /mnt/cfg/wfb.conf  ;  reboot
#
# mode      apfpv  join the air unit's WiFi AP and pull RTSP from it. Works with
#                  a stock OpenIPC/majestic camera, no pairing, short range.
#           wfb    wfb-ng: monitor mode with FEC. Needs a matching air unit and
#                  a shared key. This is the real long-range link.
mode = apfpv

# --- wfb mode only. Every one of these must match the air unit. ---
# 165 (5825 MHz) and link_id 7669206 are what OpenIPC's wifibroadcast-ng ships
# in /etc/wfb.yaml on the air unit. Its video transmitter passes no -p, so it
# uses radio_port 0; ports 144/16 and 160/32 are telemetry and the tunnel.
channel = 165
link_id = 7669206
radio_port = 0
udp_port = 5600

# Key pair. wfb-start generates one on first use if it is missing and writes
# both halves next to this file; copy drone.key to the air unit as /etc/drone.key
# (or scp your existing gs.key over the top of this one). Either half works on
# either end -- both derive the same shared secret -- but the two ends must use
# files from the same wfb_keygen run. wfb-keyinfo prints a key's public halves.
key = /mnt/cfg/wfb/gs.key

# What the air unit sends. Nothing announces this over wfb -- there is no SDP --
# so it has to be stated here. OpenIPC's defaults are h265 at 1920x1080; the
# decoder cannot scale up, so video_size must be the stream's own size.
codec = h265
video_size = 1920x1080

# Adaptive link. Scores the downlink and reports it to the air unit, which raises
# or lowers its MCS and bitrate to suit. Needs alink_drone running there, and an
# uplink to carry the reports -- on this board that is a mirrored WFB tunnel,
# started automatically. Measured on the bench: MCS 2 -> 4, 12.6 -> 23.9 Mbps.
#
# On by default. It costs nothing when the air unit is not listening, and the
# failure it used to invite -- alink_drone dropping to MCS 0 when the reports
# stop -- is now covered by a supervisor that restarts the sender.
#
# Set to 0 if this ground station must never transmit.
#
# alink_ip/alink_port are where the reports go. 10.5.0.10:9999 is alink_drone's
# default over the wfb tunnel; for the tunnel-free path, point these at the local
# wfb_tx and have the air unit's wfb_rx deliver to 127.0.0.1:9999.
alink = 1
alink_ip = 10.5.0.10
alink_port = 9999
alink_tun_name = wfb-gs
alink_tun_addr = 10.5.0.1/24
alink_tx_port = 5800
alink_rx_port = 5801
alink_tx_radio_port = 160
alink_rx_radio_port = 32

# On-screen link stats over the video: rssi, snr, MCS, bitrate, FEC and losses.
# Only the glyphs are drawn, so the picture shows through around them.
osd = 1

# --- apfpv mode only ---
ssid = OpenIPC
psk = 12345678

# Regulatory domain, as a two-letter country code. The default 00 is the world
# domain, which forbids transmitting on most 5GHz channels -- a 5GHz air unit
# will not associate reliably until this is set to your own country.
region = 00

# --- access ---
# telnet is an unencrypted console and, unlike SSH, sends the password in the
# clear. Off by default; turn it on only to recover a board whose SSH has broken,
# and only on a network you trust. telnet=1 on the kernel command line does the
# same without needing this file to be readable.
telnet = 0
WFBCONF
        echo "cfg: wrote a default $CFG_DIR/wfb.conf"
    fi
    ln -sf $CFG_DIR/wfb.conf /etc/wfb.conf
else
    echo "cfg: no 'cfg' partition, settings will NOT persist. Add to bootargs:"
    echo "     mtdparts=NOR_FLASH:11456k@0x50000(system),512k@0xf80000(cfg)"
fi

# Reads one key from the persistent config. Trims a trailing comment and outer
# whitespace but keeps inner spaces, so a passphrase containing one survives.
conf_get() {
    [ -f /etc/wfb.conf ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)\$/\1/p" /etc/wfb.conf 2>/dev/null |
        head -1 | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'
}

# PID 1 here is this shell script, not an init that handles SIGTERM, so
# busybox's reboot -- which signals PID 1 and waits for it -- does nothing at
# all. Replace the applet at BOTH paths rather than relying on /bin preceding
# /sbin: busybox installs reboot as /sbin/reboot, and a login shell's PATH is
# not the same as init's (dropbear sets its own). Flushing matters now that
# /mnt/cfg is a real filesystem: reboot(2) unmounts nothing, so a config edit
# made seconds earlier would be lost.
for a in reboot poweroff halt; do
    for d in /bin /sbin /usr/bin /usr/sbin; do
        rm -f $d/$a
        cat > $d/$a << INNER
#!/bin/sh
echo "$a: flushing and going down"
killall mi-player wfb_rx wpa_supplicant udhcpc 2>/dev/null
sync
umount $CFG_DIR 2>/dev/null
sync
exec /bin/busybox $a -f "\$@"
INNER
        chmod +x $d/$a
    done
done

# In-place firmware update, in the spirit of OpenIPC's sysupgrade. Rewriting the
# partition we booted from is safe here: U-Boot copies the whole image into RAM
# before bootm and the rootfs is an initramfs, so nothing reads flash at
# runtime. U-Boot and its environment live below 0x50000, outside the partition,
# so a failed write cannot cost the bootloader -- TFTP recovery always remains.
cat > /usr/sbin/sysupgrade << 'INNER'
#!/bin/sh
REBOOT=1
WIPE_CFG=0
INSECURE=0
SRC=
SIG=
while [ $# -gt 0 ]; do
    case $1 in
        -n) REBOOT=0 ;;
        -c) WIPE_CFG=1 ;;
        -k) INSECURE=1 ;;
        -h|--help)
            echo "usage: sysupgrade [-n] [-c] [-k] <uImage|http://url>"
            echo "  -n  write but do not reboot"
            echo "  -c  also erase /mnt/cfg (factory reset)"
            echo "  -k  skip the signature check (for images you built yourself)"
            echo "Settings in /mnt/cfg are kept unless -c is given."
            exit 0 ;;
        -*) echo "sysupgrade: unknown option $1"; exit 1 ;;
        *)  SRC=$1 ;;
    esac
    shift
done
[ -n "$SRC" ] || { echo "usage: sysupgrade [-n] [-c] [-k] <uImage|http://url>"; exit 1; }

line=$(grep '"system"' /proc/mtd)
[ -n "$line" ] || {
    echo "sysupgrade: no 'system' partition. Add to bootargs:"
    echo "  mtdparts=NOR_FLASH:11456k@0x50000(system),512k@0xf80000(cfg)"
    exit 1
}
MTD=${line%%:*}
PSIZE=$((0x$(echo "$line" | awk '{print $2}')))

# /tmp is deliberately capped at 8m and an image is bigger than that, so the
# download needs its own tmpfs. Room for two copies: unzip needs the archive and
# the extracted image at the same time.
SCRATCH=/mnt/sysupgrade
NEED_KB=$(( PSIZE / 1024 * 2 + 1024 ))
scratch_clean() { umount $SCRATCH 2>/dev/null; rmdir $SCRATCH 2>/dev/null; }
scratch_mount() {
    [ -d $SCRATCH ] && return 0
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    [ "${avail:-0}" -gt $((NEED_KB + 8192)) ] || {
        echo "sysupgrade: ${avail}K RAM free, need ~${NEED_KB}K plus headroom"
        echo "            stop the video first: fpv-stop"
        exit 1
    }
    mkdir -p $SCRATCH || exit 1
    mount -t tmpfs -o size=${NEED_KB}k none $SCRATCH || { rmdir $SCRATCH; exit 1; }
    trap scratch_clean EXIT
}

case "$SRC" in
    http://*|https://*|ftp://*)
        scratch_mount
        echo "sysupgrade: downloading $SRC"
        wget -O $SCRATCH/sysupgrade.bin "$SRC" || exit 1
        if [ $INSECURE -eq 0 ]; then
            wget -O $SCRATCH/sysupgrade.sig "$SRC.sig" 2>/dev/null &&
                SIG=$SCRATCH/sysupgrade.sig
        fi
        SRC=$SCRATCH/sysupgrade.bin ;;
    *)
        [ -f "$SRC.sig" ] && SIG=$SRC.sig ;;
esac
[ -f "$SRC" ] || { echo "sysupgrade: $SRC not found"; exit 1; }

# Accept a CI zip as well as a bare uImage. Detected by magic, not by name, so
# a renamed download still works. Scratch is RAM, so drop the archive at once.
if [ "$(od -A n -t x1 -N 4 "$SRC" | tr -d ' \n')" = "504b0304" ]; then
    echo "sysupgrade: zip archive, extracting"
    scratch_mount
    rm -rf $SCRATCH/d && mkdir -p $SCRATCH/d
    unzip -o -q "$SRC" -d $SCRATCH/d || { echo "sysupgrade: unzip failed"; exit 1; }
    [ "$SRC" = $SCRATCH/sysupgrade.bin ] && rm -f "$SRC"
    found=
    for f in $SCRATCH/d/* $SCRATCH/d/*/*; do
        [ -f "$f" ] || continue
        [ "$(od -A n -t x1 -N 4 "$f" | tr -d ' \n')" = "27051956" ] && { found=$f; break; }
    done
    [ -n "$found" ] || { echo "sysupgrade: no uImage inside the archive"; exit 1; }
    echo "sysupgrade: using $(basename "$found")"
    SRC=$found
    # CI packs the detached signature alongside the image, so a zip can still be
    # verified. Named after the image where possible, else the only .sig there.
    if [ -f "$found.sig" ]; then
        SIG=$found.sig
    else
        for s in $SCRATCH/d/*.sig $SCRATCH/d/*/*.sig; do
            [ -f "$s" ] && { SIG=$s; break; }
        done
    fi
fi

# Check before erasing, not after: a wrong file leaves an unbootable board and
# only U-Boot to recover with.
SIZE=$(wc -c < "$SRC")
magic=$(od -A n -t x1 -N 4 "$SRC" | tr -d ' \n')
load=$(od -A n -t x1 -j 16 -N 4 "$SRC" | tr -d ' \n')
dsize=$(od -A n -t x1 -j 12 -N 4 "$SRC" | tr -d ' \n')
[ "$magic" = "27051956" ] || { echo "sysupgrade: not a uImage (magic $magic)"; exit 1; }
[ "$load" = "20008000" ] || { echo "sysupgrade: load address $load, not an image for this board"; exit 1; }
# Magic and load address survive truncation, so a half-finished download would
# otherwise pass. The header's own payload length does not.
EXPECT=$((0x$dsize + 64))
[ "$SIZE" -eq "$EXPECT" ] || {
    echo "sysupgrade: size mismatch -- file is $SIZE bytes, header says $EXPECT"
    echo "            (truncated or corrupt download)"
    exit 1
}
[ "$SIZE" -le "$PSIZE" ] || { echo "sysupgrade: image $SIZE > partition $PSIZE"; exit 1; }

# Signature last, because it is the only check that says where the image came
# from. The ones above only say it is shaped like a kernel for this board, which
# an attacker who can rewrite the download can satisfy trivially -- busybox wget
# does not validate certificates, so the transport proves nothing.
if [ $INSECURE -eq 1 ]; then
    echo "sysupgrade: WARNING -- signature check skipped (-k)"
elif [ ! -x /usr/sbin/verify-sig ]; then
    echo "sysupgrade: verify-sig is missing from this image" >&2
    exit 1
elif [ -z "$SIG" ]; then
    echo "sysupgrade: no signature found for this image" >&2
    echo "            expected it next to the image as <name>.sig" >&2
    echo "            pass -k to install it anyway" >&2
    exit 1
elif ! verify-sig "$(sha256sum "$SRC" | cut -c1-64)" "$SIG"; then
    echo "sysupgrade: SIGNATURE CHECK FAILED -- refusing to install" >&2
    exit 1
else
    echo "sysupgrade: signature OK"
fi

echo "sysupgrade: $SIZE bytes -> /dev/$MTD ($PSIZE available)"
echo "sysupgrade: DO NOT POWER OFF. This takes about a minute."
# flashcp erases, writes and verifies; without -v there is no sign of progress.
if ! flashcp -v "$SRC" /dev/$MTD; then
    echo "sysupgrade: WRITE FAILED -- do not reboot, reflash over TFTP from U-Boot"
    exit 1
fi

if [ $WIPE_CFG -eq 1 ]; then
    c=$(grep '"cfg"' /proc/mtd)
    if [ -n "$c" ]; then
        umount /mnt/cfg 2>/dev/null
        flash_eraseall -j /dev/${c%%:*} >/dev/null 2>&1 &&
            echo "sysupgrade: /mnt/cfg erased, settings and host keys are gone"
    fi
fi

if [ $REBOOT -eq 1 ]; then
    echo "sysupgrade: done, rebooting"
    exec reboot
fi
echo "sysupgrade: done, reboot when ready"
INNER
chmod +x /usr/sbin/sysupgrade

# Telnet. Off unless asked for, and it authenticates when it is on: `telnetd -l
# /bin/sh` hands a root shell to anyone who can reach port 23, no password, in
# the clear. That was the lifeline while UART RX was dead and SSH unproven, but
# SSH works now and keeps its host key across reflashes, so the lifeline is just
# exposure. Enable with `telnet = 1` in /etc/wfb.conf or telnet=1 on the kernel
# command line -- the second works even when the filesystem is the problem.
# /bin/login reads /etc/shadow, so it is only useful with a root password set.
TELNET_ON=$(conf_get telnet)
for a in $(cat /proc/cmdline); do
    case "$a" in telnet=*) TELNET_ON=${a#telnet=} ;; esac
done
start_telnetd() {
    [ "$TELNET_ON" = "1" ] || return 1
    telnetd -l /bin/login
}
start_telnetd && echo "telnet: enabled on port 23 (login required)"

# SSH. Dropbear needs /dev/pts (mounted above) and a writable /var/run for its
# pid file.
#
# Host keys live on /mnt/cfg, mounted above. A RAM initramfs loses anything
# generated at boot, so the fingerprint would otherwise change every reboot;
# baking keys into the image instead would give every board flashed from it the
# same identity. /etc/dropbear is a symlink onto the persistent filesystem, so
# dropbear neither knows nor cares.
setup_host_keys() {
    if mountpoint -q $CFG_DIR 2>/dev/null; then
        mkdir -p $CFG_DIR/dropbear
        chmod 700 $CFG_DIR/dropbear
        rm -rf /etc/dropbear
        ln -sf $CFG_DIR/dropbear /etc/dropbear
    else
        mkdir -p /etc/dropbear
    fi
    [ -f /etc/dropbear/dropbear_ed25519_host_key ] && return 0
    # dropbear is built with HAVE_GETRANDOM and blocks in getrandom() until the
    # kernel CRNG is seeded. On this board that can take minutes: no RTC, no
    # disk, and few interrupts until the network and USB are busy. Hence the
    # background call below -- this must never sit on the boot path. Its own
    # "Waiting for kernel randomness" warning goes to the console rather than
    # /dev/null, so a slow first boot explains itself.
    echo "ssh: generating host keys (waits for kernel entropy, can take minutes)" > /dev/console
    for t in ed25519 ecdsa; do
        dropbearkey -t $t -f /etc/dropbear/dropbear_${t}_host_key > /dev/console 2>&1
    done
    chmod 600 /etc/dropbear/* 2>/dev/null
    if mountpoint -q $CFG_DIR 2>/dev/null; then
        echo "ssh: generated host keys, kept on $CFG_DIR" > /dev/console
    else
        echo "ssh: generated TEMPORARY host keys -- no cfg partition, so the" > /dev/console
        echo "     fingerprint changes every reboot. Add to bootargs:" > /dev/console
        echo "     mtdparts=NOR_FLASH:11456k@0x50000(system),512k@0xf80000(cfg)" > /dev/console
    fi
}

# Backgrounded as a whole: first-boot key generation blocks on kernel entropy,
# and video must not wait for it. The flag file stops the 5s supervisor from
# starting a second attempt while the first is still waiting.
start_dropbear() {
    [ -x /sbin/dropbear ] || return 1
    [ -e /tmp/dropbear.starting ] && return 0
    : > /tmp/dropbear.starting
    mkdir -p /var/run
    (
        setup_host_keys
        # Refuse password logins unless the image was built with a root password
        # hash, otherwise the account is locked ('*') and dropbear would just be
        # answering connections it can never authenticate.
        if [ "$(cat /etc/ssh-password-login 2>/dev/null)" = "1" ]; then
            dropbear -p 22 >/dev/null 2>&1
        else
            dropbear -p 22 -s >/dev/null 2>&1
        fi
        pidof dropbear >/dev/null 2>&1 &&
            echo "ssh: dropbear listening on 22" > /dev/console
        rm -f /tmp/dropbear.starting
    ) &
    return 0
}
start_dropbear && echo "ssh: starting in the background"

# Supervisor: SSH is the only interactive console on this board unless telnet is
# switched on (UART RX is dead), so losing it means a power cycle. Joining the
# drone's AP can disturb networking -- particularly if its DHCP hands out an
# address in eth0's subnet -- so re-assert eth0 and restart the daemons if any of
# them disappears.
(
    while :; do
        # Sleep first. Checking at t=0 races the startup that is still in
        # progress a few lines above -- dropbear in particular is mid-fork as it
        # daemonises, so the check saw no process and "restarted" a healthy one.
        sleep 5

        if ! ifconfig eth0 2>/dev/null | grep -q "inet addr:"; then
            # A DHCP client still negotiating is not a failure. Restarting here
            # spawns a second udhcpc: both then run the lease script, and they
            # share a pid file, so later kill-by-pidfile hits the wrong process.
            if ! eth_dhcp_running; then
                echo "net: eth0 has no address, restarting" > /dev/console
                start_eth
            fi
        fi
        # Keep eth0's subnet route ahead of any wlan0 route in the same range.
        # Derived from the live address, which DHCP may change.
        eth_net=$(ifconfig eth0 2>/dev/null | sed -n 's/.*inet addr:\([0-9]*\.[0-9]*\.[0-9]*\)\..*/\1/p')
        [ -n "$eth_net" ] && route add -net $eth_net.0 netmask 255.255.255.0 dev eth0 2>/dev/null

        if ! pidof telnetd > /dev/null 2>&1; then
            if start_telnetd; then
                echo "net: telnetd died, restarting" > /dev/console
            fi
        fi

        # The flag means startup is still in progress -- key generation can wait
        # a long time on kernel entropy, and that is not a death.
        if [ -x /sbin/dropbear ] && ! pidof dropbear > /dev/null 2>&1 &&
           [ ! -e /tmp/dropbear.starting ]; then
            echo "net: dropbear died, restarting" > /dev/console
            start_dropbear
        fi

        # With no drone AP in range wpa_supplicant retries forever, so these logs
        # grow without bound. Keep only the tail: the recent events are the ones
        # worth reading, and /tmp is RAM.
        for f in /tmp/apfpv.log /tmp/wpa.log; do
            if [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 262144 ]; then
                tail -c 65536 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            fi
        done
    done
) &

if [ -n "$ETH_IP" ]; then
    echo "Network: $ETH_IP (static)  ->  ssh root@$ETH_IP"
    [ -x /sbin/dropbear ] && echo "           ->  ssh root@$ETH_IP"
else
    echo "Network: eth0 requesting DHCP as 'nvr-gs'"
    echo "         the address is printed below once the lease arrives,"
    echo "         and is shown on the HDMI overlay"
fi
echo ""

# Run it automatically: without UART input this is the only way to see the result.
# The set is chosen on the kernel command line (mi_set=sdk|xm|hybrid) because the
# modules cannot be unloaded and reloaded -- switching requires a reboot.
# 'xm' is the default: it is the only set whose ABI matches the shipped
# libmi_*.so (the SDK's own modules are a newer build than its libraries and
# make MI_SYS_Init fail with 0xa009201f).
MI_SET=xm
VDEC_DEBUG=0
for arg in $(cat /proc/cmdline); do
    case $arg in
        mi_set=*) MI_SET=${arg#mi_set=} ;;
        vdec_debug=*) VDEC_DEBUG=${arg#vdec_debug=} ;;
    esac
done
load-mi $MI_SET $VDEC_DEBUG
echo ""
echo "--- lsmod ---"
lsmod
echo ""

# Bring the display up automatically. mi-disp-init never returns by design: it
# holds /dev/mi_hdmi open, and closing that fd releases the HDMI client and stops
# the transmitter. So it has to stay resident in the background rather than run
# once. Resolution can be overridden with disp=720 on the kernel command line.
DISP_MODE=""
for arg in $(cat /proc/cmdline); do
    case $arg in
        disp=720) DISP_MODE=720 ;;
        disp=off) DISP_MODE=off ;;
    esac
done

if [ "$DISP_MODE" = "off" ]; then
    echo "display: disabled (disp=off)"
else
    mi-disp-init $DISP_MODE > /tmp/mi-disp-init.log 2>&1 &

    # Poll rather than sleeping a fixed time: MI_HDMI_Start only returns once the
    # transmitter has read EDID and finished its HPD handshake, which varies with
    # the monitor.
    n=0
    while [ $n -lt 15 ]; do
        grep -q "MI_HDMI_Start" /tmp/mi-disp-init.log 2>/dev/null && break
        n=$((n + 1))
        sleep 1
    done

    if grep -q "MI_HDMI_Start.*ok" /tmp/mi-disp-init.log 2>/dev/null; then
        echo "display: HDMI up"
    else
        echo "display: HDMI did not confirm -- see /tmp/mi-disp-init.log"
    fi

    # Draw regardless of the check above: the framebuffer is an independent OSD
    # layer, so a splash may well appear even if the HDMI probe was inconclusive.
    if [ -x /bin/fb-splash ] && [ -e /dev/fb0 ]; then
        sleep 1
        # The lease may not have arrived yet; the live stats overlay replaces
        # this line as soon as it does.
        eth_ip=$(cat /tmp/eth-ip 2>/dev/null)
        [ -n "$eth_ip" ] || eth_ip=$(ifconfig eth0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
        [ -n "$eth_ip" ] || eth_ip="DHCP PENDING"
        fb-splash -p "OPENIPC GROUND STATION" \
                     "SSR621Q HDMI OK" \
                     "TELNET $eth_ip" > /tmp/fb-splash.log 2>&1 \
            && echo "display: splash drawn" \
            || echo "display: splash failed -- see /tmp/fb-splash.log"
    fi
fi
echo ""
echo "To try another set, reboot with mi_set=sdk|xm|hybrid on the kernel cmdline."
echo "Do NOT rmmod these modules -- it oopses the kernel."
echo ""

# ── Link configuration ────────────────────────────────────────────────────────
# Started last and in the background: telnetd is already up by this point, so a
# wifi problem can never cost us the only usable console.
#
# Three sources, lowest to highest precedence: built-in default, the persistent
# config file, then the kernel command line. The file is what you edit over SSH;
# the command line stays as the override that does not need a working filesystem.
#   apfpv=off                 disable the link entirely
#   apfpv_ssid= apfpv_psk=    air unit SSID and key
#   wifi_cc=                  regulatory domain
APFPV_ON=1
APFPV_SSID=$(conf_get ssid)
APFPV_PSK=$(conf_get psk)
# Regulatory domain for the wifi driver, as an alpha2. The default 00 (world)
# forbids active scanning and TX on most 5GHz channels, so a 5GHz air unit will
# not associate reliably. Set this to your own country.
WIFI_CC=$(conf_get region)
for arg in $(cat /proc/cmdline); do
    case $arg in
        apfpv=off)   APFPV_ON=0 ;;
        apfpv_ssid=*) APFPV_SSID=${arg#apfpv_ssid=} ;;
        apfpv_psk=*)  APFPV_PSK=${arg#apfpv_psk=} ;;
        wifi_cc=*)    WIFI_CC=${arg#wifi_cc=} ;;
    esac
done
[ -n "$APFPV_SSID" ] || APFPV_SSID=OpenIPC
[ -n "$APFPV_PSK" ]  || APFPV_PSK=12345678
[ -n "$WIFI_CC" ]    || WIFI_CC=00
echo "$WIFI_CC" > /etc/wifi-cc

# ── Link mode: apfpv or wfb-ng ────────────────────────────────────────────────
# The two are mutually exclusive -- apfpv needs the adapter in managed mode
# associated to the air unit's AP, wfb-ng needs monitor mode with no association
# at all -- so exactly one runs. The persistent config is the primary source so
# it can be changed over SSH; link= on the command line overrides it, which is
# the way back if a config edit leaves the board unable to see the drone.
LINK_MODE=""
for arg in $(cat /proc/cmdline); do
    case $arg in
        link=*) LINK_MODE=${arg#link=} ;;
    esac
done
if [ -z "$LINK_MODE" ] && [ -f /etc/wfb.conf ]; then
    LINK_MODE=$(sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*\([a-z]*\).*/\1/p' /etc/wfb.conf | head -1)
fi
[ -n "$LINK_MODE" ] || LINK_MODE=apfpv
[ $APFPV_ON -eq 1 ] || LINK_MODE=off

case $LINK_MODE in
    wfb)
        echo "link: wfb-ng (log: /tmp/wfb.log) -- edit /mnt/cfg/wfb.conf to change"
        (wfb-start > /tmp/wfb.log 2>&1) &
        ;;
    apfpv)
        echo "apfpv: autostarting for SSID '$APFPV_SSID' (log: /tmp/apfpv.log)"
        (apfpv "$APFPV_SSID" "$APFPV_PSK" > /tmp/apfpv.log 2>&1) &
        ;;
    *)
        echo "link: disabled ($LINK_MODE)"
        ;;
esac
echo ""

# ── VDEC diagnostic mode ──────────────────────────────────────────────────────
# Run the decoder investigation straight from init, with everything on the serial
# console. telnetd has now died three times mid-session, and UART RX does not
# work, so a test that depends on an interactive shell is a test that keeps being
# lost. This needs no console at all: boot, then start the sender.
#   vdec_test=1               run it, driver debug output on
#   vdec_test_src=WxH         source resolution (default 1280x720)
#   vdec_test_dumpbs=1        dump the ES the driver hands the VPU to /tmp/bs.h264
#   vdec_test_vpulog=N        VPU log level (default 1). 3 is a per-command
#                             register dump: it floods a 115200 console and
#                             starves the board. Use 0 to leave it off.
VDEC_TEST=0
VDEC_TEST_SRC=1280x720
VDEC_TEST_DUMPBS=0
VDEC_TEST_VPULOG=1
VDEC_TEST_LOG=3
VDEC_TEST_FILE=
VDEC_TEST_RTSP=
VDEC_TEST_PROBE=0
VDEC_TEST_OPTS=
for arg in $(cat /proc/cmdline); do
    case $arg in
        vdec_test=1)         VDEC_TEST=1 ;;
        vdec_test_src=*)     VDEC_TEST_SRC=${arg#vdec_test_src=} ;;
        vdec_test_dumpbs=1)  VDEC_TEST_DUMPBS=1 ;;
        vdec_test_vpulog=*)  VDEC_TEST_VPULOG=${arg#vdec_test_vpulog=} ;;
        vdec_test_log=*)     VDEC_TEST_LOG=${arg#vdec_test_log=} ;;
        vdec_test_noscale=1) VDEC_TEST_OPTS="$VDEC_TEST_OPTS -noscale" ;;
        vdec_test_esflag=*)  VDEC_TEST_OPTS="$VDEC_TEST_OPTS -esflag ${arg#vdec_test_esflag=}" ;;
        # Feed a known-good Annex-B file instead of UDP. The decoder reports
        # "not found sps"; this takes the network and the RTP depacketiser out
        # of the path so the bitstream itself can be judged on its own.
        vdec_test_file=1)    VDEC_TEST_FILE=/usr/share/test720.h264 ;;
        vdec_test_file=*)    VDEC_TEST_FILE=${arg#vdec_test_file=} ;;
        # Pull from an RTSP camera. OpenIPC/majestic streams nothing until a
        # client has issued PLAY, so listening on UDP alone never sees video.
        # vdec_test_rtsp=1 uses the OpenIPC defaults on the AP's gateway.
        vdec_test_rtsp=1)    VDEC_TEST_RTSP=auto ;;
        vdec_test_rtsp=*)    VDEC_TEST_RTSP=${arg#vdec_test_rtsp=} ;;
        vdec_test_probe=1)   VDEC_TEST_PROBE=1 ;;
    esac
done

if [ $VDEC_TEST -eq 1 ]; then
    PROC=/proc/mi_modules/mi_vdec/mi_vdec0
    # XiongMai ships mi_vdec logging at 0(NONE) while every other module sits at
    # 2(WRN), which is why the decoder's own "init seq not ready, errorReason"
    # message never reaches the console. The insmod debug_level parameter does
    # NOT drive this -- only mi_log_info does.
    echo "mi_vdec=$VDEC_TEST_LOG" > /proc/mi_modules/mi_log_info 2>/dev/null \
        && echo "vdec-test: mi_vdec log level set to $VDEC_TEST_LOG"
    echo "vdec-test: starting player, source $VDEC_TEST_SRC$VDEC_TEST_OPTS -- send video to UDP 5600"
    if [ -z "$VDEC_TEST_RTSP" ]; then
        # Only tear the splash down when the player starts immediately. In RTSP
        # mode the picture may be a minute away, and mi-disp-init is what holds
        # /dev/mi_hdmi open -- killing it here would blank the screen while we
        # wait. fpv-start does both at link-up instead.
        killall mi-disp-init 2>/dev/null
        killall fb-splash 2>/dev/null
        [ -e /dev/fb0 ] && dd if=/dev/zero of=/dev/fb0 bs=64k 2>/dev/null
    fi
    sleep 1
    # The alkaid set has its own binary linked against its own libraries.
    PLAYER=mi-player
    [ "$MI_SET" = "alkaid" ] && PLAYER=mi-player-alkaid
    if [ -n "$VDEC_TEST_FILE" ]; then
        echo "vdec-test: feeding $VDEC_TEST_FILE (no network, no RTP)"
        $PLAYER -f "$VDEC_TEST_FILE" -s "$VDEC_TEST_SRC" $VDEC_TEST_OPTS \
            > /dev/console 2>&1 &
    elif [ -n "$VDEC_TEST_RTSP" ]; then
        # Do not start anything yet, and do not poll for an address either.
        # Record what to play; the DHCP bound/renew handler calls fpv-start the
        # instant the link comes up, and fpv-stop when it goes away. Until then
        # the boot splash stays on screen.
        cat > /tmp/fpv.conf << FPVEOF
FPV_URL='$VDEC_TEST_RTSP'
FPV_SRC='$VDEC_TEST_SRC'
FPV_OPTS='$VDEC_TEST_OPTS'
FPV_PLAYER='$PLAYER'
FPV_USER='root'
FPV_PASS='12345'
FPVEOF
        if [ "$VDEC_TEST_RTSP" = auto ]; then
            echo "vdec-test: RTSP armed -- will stream from the DHCP gateway"
        else
            echo "vdec-test: RTSP armed -- $VDEC_TEST_RTSP"
        fi
        echo "vdec-test: waiting for the air unit (fpv-start runs on the lease)"
    else
        $PLAYER -u 5600 -s "$VDEC_TEST_SRC" $VDEC_TEST_OPTS > /dev/console 2>&1 &
    fi
    sleep 3

    if [ -e $PROC ]; then
        echo "vdec-test: ---- $PROC (before stream) ----"
        cat $PROC
        # The VPU's own log is the one layer never yet observed. Five args:
        # the parser wants a trailing 'mode' the help text does not mention.
        if [ "$VDEC_TEST_VPULOG" != "0" ]; then
            echo vpulog 0 on $VDEC_TEST_VPULOG 1 > $PROC 2>/dev/null
            echo "vdec-test: vpulog level $VDEC_TEST_VPULOG enabled"
        fi
        echo flowdbg on > $PROC 2>/dev/null
        if [ $VDEC_TEST_DUMPBS -eq 1 ]; then
            # Capture what the driver actually feeds the VPU, so the bitstream
            # can be checked independently of our depacketiser. The argument is
            # a directory: the driver names the file itself.
            echo dumpbs 0 /tmp > $PROC 2>/dev/null
            echo "vdec-test: dumping driver-side bitstream under /tmp"
        fi
    else
        echo "vdec-test: $PROC missing -- listing what the driver does expose:"
        ls /proc/mi_modules/ 2>/dev/null || echo "  (no /proc/mi_modules)"
    fi

    # Dump the driver's view periodically so the failing state is visible without
    # anyone having to log in.
    (
        while :; do
            sleep 20
            [ -e $PROC ] && { echo "vdec-test: ---- $PROC ----"; cat $PROC; }
        done
    ) &

    # Ask the driver directly whether the VPU is seeing our bytes, using its own
    # debug commands rather than inference from counters.
    if [ $VDEC_TEST_PROBE -eq 1 ] && [ -e $PROC ]; then
        (
            sleep 8
            # dumpbs is a toggle: the second write stops it and closes the file.
            echo dumpbs 0 /tmp > $PROC 2>/dev/null
            sleep 3
            echo dumpbs 0 /tmp > $PROC 2>/dev/null
            # dumpbsb writes out the VPU's bitstream buffer as it stands.
            echo dumpbsb 0 /tmp > $PROC 2>/dev/null
            sleep 2

            echo "vdec-probe: ================ dumps ================"
            for f in /tmp/chn_0_*; do
                [ -f "$f" ] || continue
                # A buffer of nothing but zeros means the elementary stream
                # never reached the VPU at all, which separates a delivery
                # problem from a parsing one. busybox od has no 'z' type.
                echo "vdec-probe: $f"
                echo "  size $(wc -c < "$f"), non-zero $(tr -d '\000' < "$f" | wc -c)"
                od -A x -t x1 -N 128 "$f"
            done
        ) &
    fi
fi
echo ""

# Never return: init exiting causes "Attempted to kill init!" panic.
# The shell must be a session leader with /dev/ttyS0 as its controlling terminal,
# otherwise keyboard input from the UART never reaches it. setsid starts a new
# session and cttyhack claims the tty it inherits as the ctty.
while true; do
    setsid cttyhack /bin/sh < /dev/ttyS0 > /dev/ttyS0 2>&1
    echo "(shell exited, restarting)" > /dev/ttyS0
done
EOF
chmod +x $INITRAMFS_DIR/init

# Device nodes cannot be created in the staging directory without root, so they are
# declared as gen_init_cpio directives instead. /dev/console must exist in the cpio
# or the kernel cannot give init a stdin/stdout.
cat > $INITRAMFS_NODES << 'EOF'
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/tty 0666 0 0 c 5 0
dir /dev/net 0755 0 0
nod /dev/net/tun 0660 0 0 c 10 200
EOF

# ── Kernel ────────────────────────────────────────────────────────────────────
echo "=== [5/5] Building SDK kernel ($DEFCONFIG) ==="
cd $KERNEL_DIR
make $DEFCONFIG

# ── Device tree: restore the PIU timer node ──────────────────────────────────
# XiongMai's mi_vdec.ko drives its decode work off the PIU timer: it looks the
# node up with of_find_compatible_node("sstar,piu-clocksource"), resolves the
# platform device with of_find_device_by_node(), and installs its own
# TimerirqHandler. Every SigmaStar board dtsi has that node commented out (they
# use the ARM architected timer), so the lookup fails, the timer interrupt never
# fires, and queued frames are never decoded. The symptom is MI_VDEC_GetChnStat
# reporting frames received but decoded=0, with no decode error, no VPU firmware
# banner, and "TimerProbe ... Fail!" as the only warning.
#
# status must be "ok": of_platform_populate() only creates a platform device for
# an available node, and without one of_find_device_by_node() fails. That is
# safe here because CONFIG_MS_PIU_TIMER is not set, so the kernel's own driver
# for this compatible is not built and nothing else touches the timer or its
# interrupt -- mi_vdec gets the hardware to itself.
#
# The interrupt specifier must be three cells with no phandle, matching the
# other working nodes in this file (see rtcpwc / dec): ms_main_intc declares
# #interrupt-cells = <3> and the soc node already sets interrupt-parent. The
# vendor's commented-out copy of this node has a four-cell form with the parent
# phandle inlined; copying that verbatim maps the wrong interrupt, so the timer
# probes successfully but never fires.
python3 - "$KERNEL_DIR/arch/arm/boot/dts/infinity2m.dtsi" << 'PYEOF'
import re
import sys

path = sys.argv[1]
src = open(path).read()

node = '''
        /* piu_timer_for_vdec: required by the XM mi_vdec.ko -- see build-sdk.sh */
        timer_clockevent: timer@1F006040 {
            compatible = "sstar,piu-clocksource","sstar,piu-clockevent";
            reg = <0x1F006040 0x100>;
            interrupts = <GIC_SPI INT_FIQ_TIMER_0 IRQ_TYPE_LEVEL_HIGH>;
            clocks = <&CLK_xtali_12m>;
            status = "ok";
        };
'''

# Drop any node this script added previously, so the definition below always
# wins even if an earlier build inserted a different one.
src, dropped = re.subn(r'\n[ \t]*/\* piu_timer_for_vdec.*?\n[ \t]*\};\n',
                       '\n', src, flags=re.S)

# Insert after the vendor's commented-out copy, which is an unambiguous anchor.
i = src.index('timer_clockevent: timer@1F006040')
j = src.index('*/', i) + 2
open(path, 'w').write(src[:j] + '\n' + node + src[j:])
print("dts: %s PIU timer node for mi_vdec" % ("replaced" if dropped else "added"))
PYEOF

# A known-good 720p Annex-B clip (SPS/PPS/IDR, 90 access units) so the decoder
# can be tested without the network or the RTP depacketiser in the path.
if [ "${INCLUDE_VDEC_TEST_ASSET:-0}" = 1 ] && [ -f $SCRIPT_DIR/assets/test720.h264 ]; then
    mkdir -p $INITRAMFS_DIR/usr/share
    cp $SCRIPT_DIR/assets/test720.h264 $INITRAMFS_DIR/usr/share/
else
    echo "decoder test clip: omitted (set INCLUDE_VDEC_TEST_ASSET=1 to stage it)"
fi

# Fallback MAC, used only if U-Boot did not pass ethaddr= on the command line.
# Locally administered (02:...) and random, so no real board's address is ever
# baked into an image. It is cached in .fallback-mac (gitignored) because a MAC
# that changes on every rebuild makes the DHCP server issue a new lease each
# time, which strands the old address and breaks ARP for anyone talking to it.
# Set FALLBACK_MAC in the environment to override.
mkdir -p $INITRAMFS_DIR/etc
MAC_CACHE=$SCRIPT_DIR/.fallback-mac
if [ -z "${FALLBACK_MAC:-}" ] && [ -f "$MAC_CACHE" ]; then
    FALLBACK_MAC=$(cat "$MAC_CACHE")
fi
if [ -z "${FALLBACK_MAC:-}" ]; then
    FALLBACK_MAC=$(od -An -N5 -tu1 /dev/urandom |
        awk '{printf "02:%02x:%02x:%02x:%02x:%02x", $1, $2, $3, $4, $5}')
    echo "$FALLBACK_MAC" > "$MAC_CACHE"
fi
echo "$FALLBACK_MAC" > $INITRAMFS_DIR/etc/fallback-mac
echo "network: fallback MAC $FALLBACK_MAC (real one comes from U-Boot ethaddr=)"

# Strip debug info from every shared library and binary in the rootfs. The
# toolchains ship unstripped runtimes -- the ARM 8.2 libc-2.28.so alone is
# 15.8M, libgcc_s.so.1 8.6M -- and the initramfs is unpacked into ramfs at
# boot, so every wasted megabyte is a megabyte of RAM. Overshoot it and the
# kernel dies with "write error" before init ever runs. --strip-debug only
# drops debug sections, never the dynamic symbols the loader needs.
find $INITRAMFS_DIR/lib $INITRAMFS_DIR/usr/lib -name "*.so*" -type f \
    -exec ${CROSS_COMPILE}strip --strip-debug {} + 2>/dev/null || true
echo "initramfs: $(du -sh $INITRAMFS_DIR | cut -f1) after stripping"

# Embed the initramfs so the board can boot entirely over TFTP, with no flash
# writes and no dependency on the stock partition layout.
./scripts/config --enable BLK_DEV_INITRD \
                 --enable RD_GZIP \
                 --set-str INITRAMFS_SOURCE "$INITRAMFS_DIR $INITRAMFS_NODES" \
                 --set-val INITRAMFS_ROOT_UID 0 \
                 --set-val INITRAMFS_ROOT_GID 0

# USB host and cfg80211 built in, not modular. 88XXau_wfb.ko needs 28 cfg80211/
# ieee80211 symbols and 12 usb_* symbols; the defconfig has both as =m, and we
# build no kernel modules of our own, so as modules they would simply be absent.
# Building them in also avoids any insmod ordering issues on the target.
#
# NET_CORE has to be named explicitly even though only TUN is wanted: TUN sits
# inside `if NET_CORE` in drivers/net/Kconfig, and this defconfig leaves it off,
# so olddefconfig silently drops CONFIG_TUN when only TUN is enabled.
./scripts/config --enable USB \
                 --enable USB_COMMON \
                 --enable USB_EHCI_HCD \
                 --enable USB_STORAGE \
                 --enable CFG80211 \
                 --enable CFG80211_WEXT \
                 --enable NET_CORE \
                 --enable TUN
make olddefconfig

# -fcommon: the bundled scripts/dtc defines yylloc in two objects, which modern
# host gcc rejects because -fno-common became the default in gcc 10.
HOSTCFLAGS="-Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -std=gnu89 -fcommon"

# ── RTL8812AU ─────────────────────────────────────────────────────────────────
# Built here, not in a script of its own, because it has to see the kernel config
# set just above: vermagic comes from it and the module would be rejected at
# insmod otherwise. modules_prepare is enough -- the driver resolves its kernel
# symbols when it is loaded, not when it is linked, which is why Module.symvers
# can stay empty. This has to land in the initramfs before Image links it in.
RTL_DIR=$BUILD_DIR/rtl8812au
[ -d $RTL_DIR ] || { echo "error: $RTL_DIR missing -- run ./fetch-deps.sh" >&2; exit 1; }

grep -q '<linux/version.h>' $RTL_DIR/core/rtw_br_ext.c ||
    patch -p1 -d $RTL_DIR < $SCRIPT_DIR/patches/0003-rtl8812au-include-linux-version.patch

make -j$JOBS HOSTCFLAGS="$HOSTCFLAGS" modules_prepare
# KSRC is := in the driver Makefile, but command line wins over any assignment.
make -C $RTL_DIR -j$JOBS ARCH=arm CROSS_COMPILE=$CROSS_COMPILE KSRC=$KERNEL_DIR

RTL_KO=$RTL_DIR/88XXau_wfb.ko
[ -f $RTL_KO ] || { echo "error: driver build produced no 88XXau_wfb.ko" >&2; exit 1; }
mkdir -p $INITRAMFS_DIR/lib/modules/wifi
cp $RTL_KO $INITRAMFS_DIR/lib/modules/wifi/
${CROSS_COMPILE}strip --strip-debug $INITRAMFS_DIR/lib/modules/wifi/88XXau_wfb.ko
echo "wifi: built 88XXau_wfb.ko ($(stat -c%s $INITRAMFS_DIR/lib/modules/wifi/88XXau_wfb.ko) bytes)"

# ── RTL8812EU ────────────────────────────────────────────────────────────────
# The BL-M8812EU2 and friends. Same story as above -- it has to see this kernel
# config for vermagic. Realtek's Makefile ships configured for an x86 PC and
# picks its own toolchain paths per platform; ARM_RPI is the generic 32-bit ARM
# one, and KSRC/CROSS_COMPILE on the command line override what it sets.
RTLEU_DIR=$BUILD_DIR/rtl8812eu
if [ -d $RTLEU_DIR ]; then
    grep -q '^CONFIG_PLATFORM_ARM_RPI = y' $RTLEU_DIR/Makefile ||
        patch -p1 -d $RTLEU_DIR < $SCRIPT_DIR/patches/0006-rtl8812eu-arm-platform.patch
    make -C $RTLEU_DIR -j$JOBS ARCH=arm CROSS_COMPILE=$CROSS_COMPILE KSRC=$KERNEL_DIR

    RTLEU_KO=$RTLEU_DIR/8812eu.ko
    [ -f $RTLEU_KO ] || { echo "error: driver build produced no 8812eu.ko" >&2; exit 1; }
    cp $RTLEU_KO $INITRAMFS_DIR/lib/modules/wifi/
    ${CROSS_COMPILE}strip --strip-debug $INITRAMFS_DIR/lib/modules/wifi/8812eu.ko
    echo "wifi: built 8812eu.ko ($(stat -c%s $INITRAMFS_DIR/lib/modules/wifi/8812eu.ko) bytes)"
else
    echo "error: $RTLEU_DIR missing -- run ./fetch-deps.sh" >&2
    exit 1
fi

# Build zImage, not uImage, even though the board boots the uncompressed image.
# Two rules in arch/arm/boot/Makefile write uImage: SigmaStar's, which hangs off
# the zImage recipe and wraps the raw Image with the bundled scripts/mkimage; and
# the stock one, which wraps zImage itself and needs host mkimage. The stock rule
# is absent here but present on CI runners, so asking for uImage published a
# compressed self-extracting kernel from CI and an uncompressed one from here.
# The same zImage recipe also runs ms_builtin_dtb_update.py, which appends the
# board DTB to Image -- asking for Image alone silently skips it.
make -j$JOBS HOSTCFLAGS="$HOSTCFLAGS" zImage

UIMAGE=$KERNEL_DIR/arch/arm/boot/uImage
if [ ! -f $UIMAGE ]; then
    echo "error: kernel build produced no uImage" >&2
    exit 1
fi

# Reject a stale or truncated image rather than booting something broken.
python3 - "$UIMAGE" "$KERNEL_DIR/arch/arm/boot/Image" << 'PYEOF'
import os, struct, sys
h = open(sys.argv[1], 'rb').read(64)
if len(h) < 64:
    sys.exit("uImage is truncated")
magic, _, _, size, load, entry, _ = struct.unpack('>7I', h[:28])
if magic != 0x27051956:
    sys.exit("bad uImage magic: %08x" % magic)
if load != 0x20008000 or entry != 0x20008000:
    sys.exit("unexpected load/entry: %08x/%08x" % (load, entry))
# A zImage wrapper also passes the checks above, so compare against Image: it is
# the only way to tell a stale uImage from the stock rule apart from ours.
raw = os.path.getsize(sys.argv[2])
if size != raw:
    sys.exit("uImage payload is %d bytes but Image is %d -- wrong wrapper" % (size, raw))
if os.path.getsize(sys.argv[1]) != size + 64:
    sys.exit("uImage size does not match its own header")
print("uImage OK: %d bytes, load %08x, name %s"
      % (size, load, h[32:64].split(b'\0')[0].decode('latin1')))
PYEOF

cp $UIMAGE $OUTPUT_DIR/uImage-sdk

# Flash layout, read off the stock dump (NBD80S10S-KL_original.bin):
#   0x000000  IPL + IPL_CUST                     keep
#   0x010000  U-Boot (uImage-wrapped, XZ)        keep
#   0x040000  U-Boot environment (CRC32 + vars)  keep -- saveenv writes here
#   0x050000  stock kernel + rootfs squashfs     ours, to end of chip
# Everything from 0x50000 up is the stock OS, which we replace wholesale. That
# is also exactly where the stock `loadromfs` read from, so the bootloader's
# view of the world does not change.
FLASH_SIZE=$((0x1000000))
FLASH_OFFSET=$((0x50000))
FLASH_AVAIL=$((FLASH_SIZE - FLASH_OFFSET))
UIMAGE_SIZE=$(stat -c %s $OUTPUT_DIR/uImage-sdk)
# sf erase needs a 64KB-aligned length; round up.
ERASE_LEN=$(( (UIMAGE_SIZE + 0xFFFF) & ~0xFFFF ))

if [ $UIMAGE_SIZE -gt $FLASH_AVAIL ]; then
    echo "ERROR: uImage ($UIMAGE_SIZE bytes) exceeds the $FLASH_AVAIL bytes" \
         "available above 0x50000. Trim MI_SETS or the rootfs." >&2
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== SDK kernel build complete ==="
ls -lh $OUTPUT_DIR/uImage-sdk
echo ""
echo "Modules built: $(ls $MI_OUT/modules | tr '\n' ' ')  (shipping: $MI_SETS)"
printf 'Image %d bytes, flash window %d bytes from 0x%x -- %d KB spare\n' \
    "$UIMAGE_SIZE" "$FLASH_AVAIL" "$FLASH_OFFSET" \
    "$(( (FLASH_AVAIL - UIMAGE_SIZE) / 1024 ))"
echo ""
echo "RAM-boot over TFTP (does not touch flash):"
echo "  tftpboot 0x21000000 uImage-sdk"
echo "  setenv bootargs console=ttyS0,115200 LX_MEM=0xFF00000 \\"
echo "      mma_heap=mma_heap_name0,miu=0,sz=0x6e00000 mma_memblock_remove=1 mi_set=xm"
echo "  bootm 0x21000000"
echo ""
printf 'Flash it (replaces the stock OS, keeps IPL/U-Boot/env):\n'
printf '  tftpboot 0x21000000 uImage-sdk\n'
printf '  sf probe 0\n'
printf '  sf lock 0                      # REQUIRED: sets lock LEVEL 0, i.e. unlocks.\n'
printf '                                 # The chip ships with the lower 8MB write\n'
printf '                                 # protected (boot prints "lk=>6, 0x800000").\n'
printf '                                 # Without it erase/write report OK and do nothing.\n'
printf '  sf erase 0x%x 0x%x\n' "$FLASH_OFFSET" "$ERASE_LEN"
printf '  sf write 0x21000000 0x%x ${filesize}\n' "$FLASH_OFFSET"
echo ""
printf 'Test before committing to it:\n'
printf '  sf read 0x21000000 0x%x 0x%x\n' "$FLASH_OFFSET" "$ERASE_LEN"
echo "  bootm 0x21000000"
echo ""
printf 'Then make it permanent:\n'
printf "  setenv setargs 'setenv bootargs console=ttyS0,115200 LX_MEM=0xFF00000 mma_heap=mma_heap_name0,miu=0,sz=0x6e00000 mma_memblock_remove=1 mtdparts=NOR_FLASH:11456k@0x50000(system),512k@0xf80000(cfg) ethaddr=\${ethaddr} mi_set=xm vdec_test=1 vdec_test_rtsp=1 vdec_test_src=1920x1080'\n"
printf "  setenv bootcmd 'run setargs;gpio output 25 1;sf probe 0;sf read 0x21000000 0x%x 0x%x;bootm 0x21000000'\n" \
    "$FLASH_OFFSET" "$ERASE_LEN"
echo "  setenv bootdelay 3"
echo "  saveenv"
echo ""
echo "Build bootargs INSIDE setargs, as above. U-Boot expands \${} only once, so"
echo "the older two-step form (setenv bootargs '...\${ethaddr}...' plus a setargs"
echo "that re-sets it) passes the literal text \${ethaddr} to the kernel and the"
echo "board falls back to a random MAC. Here \${ethaddr} expands when setargs runs."
echo ""
echo "eth0 uses DHCP and registers the hostname 'nvr-gs', so look for that in your"
echo "router's client list. With no DHCP server it falls back to 192.168.1.10."
echo "Pass ipaddr=A.B.C.D to force a static address instead -- if you do, keep it"
echo "outside the router's DHCP pool or the same address can be leased elsewhere."
echo ""
echo "mtdparts gives the board one erase block at the top of flash to keep its SSH"
echo "host keys in. They are generated on first boot, so no private key ships in"
echo "the image and every board has its own identity. Without it SSH still works,"
echo "but the fingerprint changes on every reboot."
