################################################################################
#
# gs-tools
#
# The ground station's own programs, built from src/ in this repository.
# Compile lines carried over from the vendor-SDK build; the notes below explain
# the ones that are
# not obvious, and the important ones are repeated here.
#
################################################################################

GS_TOOLS_VERSION = 1.0
GS_TOOLS_SITE = $(BR2_EXTERNAL_SSR621Q_FPV_PATH)/../src
GS_TOOLS_SITE_METHOD = local
GS_TOOLS_LICENSE = GPL-2.0
GS_TOOLS_DEPENDENCIES = sigmastar-mi

GS_TOOLS_PUBKEY = $(BR2_EXTERNAL_SSR621Q_FPV_PATH)/../signing-key.pub

GS_TOOLS_MI_CFLAGS = -I$(STAGING_DIR)/usr/include
GS_TOOLS_MI_LDFLAGS = -L$(STAGING_DIR)/usr/lib \
	-lmi_sys -lmi_disp -lmi_vdec -lmi_divp -lmi_common -lpthread -lm -ldl \
	-Wl,-rpath,/usr/lib

define GS_TOOLS_BUILD_CMDS
	# verify-sig embeds the public key, so a signature only passes if it came
	# from our key however the image arrived. A verifier that is quietly
	# absent is worse than none: sysupgrade would fall back to trusting the
	# download, and busybox wget does not validate certificates.
	test -s $(GS_TOOLS_PUBKEY)
	test "$$(stat -c%s $(GS_TOOLS_PUBKEY))" = "32"
	python3 -c "import sys; print(','.join('0x%02x' % b for b in open(sys.argv[1],'rb').read()))" \
		$(GS_TOOLS_PUBKEY) > $(@D)/signing-pubkey.h

	$(TARGET_CC) -O2 -o $(@D)/mi-disp-init $(@D)/mi-disp-init.c \
		$(GS_TOOLS_MI_CFLAGS) $(GS_TOOLS_MI_LDFLAGS)

	# -rdynamic puts the player's own symbols in .dynsym so libmi_vdec.so binds
	# to the ioctl() defined in mi-player.c, which corrects the VDEC ioctl
	# numbering mismatch between the 2020 libraries and the 2023 XM modules.
	$(TARGET_CC) -O2 -o $(@D)/mi-player $(@D)/mi-player.c \
		$(GS_TOOLS_MI_CFLAGS) $(GS_TOOLS_MI_LDFLAGS) -rdynamic

	# Deliberately dependency-free: the wfb driver implements IW_MODE_MONITOR
	# through wireless extensions, so this avoids cross-compiling iw + libnl.
	$(TARGET_CC) -O2 -o $(@D)/wifi-monitor $(@D)/wifi-monitor.c
	$(TARGET_CC) -O2 -o $(@D)/fb-splash $(@D)/fb-splash.c
	$(TARGET_CC) -O2 -o $(@D)/alink-gs $(@D)/alink-gs.c

	$(TARGET_CC) -O2 -o $(@D)/wfb-keyinfo -I$(@D)/tweetnacl \
		$(@D)/wfb-keyinfo.c $(@D)/tweetnacl/tweetnacl.c
	$(TARGET_CC) -O2 -o $(@D)/verify-sig -I$(@D)/tweetnacl -I$(@D) \
		$(@D)/verify-sig.c $(@D)/tweetnacl/tweetnacl.c
endef

define GS_TOOLS_INSTALL_TARGET_CMDS
	$(foreach b,mi-disp-init mi-player wifi-monitor fb-splash, \
		$(INSTALL) -D -m 0755 $(@D)/$(b) $(TARGET_DIR)/bin/$(b)
	)
	$(foreach b,alink-gs wfb-keyinfo, \
		$(INSTALL) -D -m 0755 $(@D)/$(b) $(TARGET_DIR)/usr/bin/$(b)
	)
	$(INSTALL) -D -m 0755 $(@D)/verify-sig $(TARGET_DIR)/usr/sbin/verify-sig
endef

$(eval $(generic-package))
