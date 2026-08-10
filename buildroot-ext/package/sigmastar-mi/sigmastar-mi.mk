################################################################################
#
# sigmastar-mi
#
# Prebuilt vendor blobs, so there is no source to download or build -- only an
# install step. The layout mirrors the stock firmware's, because that is the
# combination known to decode video and drive HDMI on this board.
#
################################################################################

SIGMASTAR_MI_VERSION = xm-f947025
SIGMASTAR_MI_SOURCE =
SIGMASTAR_MI_LICENSE = PROPRIETARY
SIGMASTAR_MI_REDISTRIBUTE = NO
# gs-tools compiles against these headers and links these libraries.
SIGMASTAR_MI_INSTALL_STAGING = YES

SIGMASTAR_MI_TOP = $(BR2_EXTERNAL_SSR621Q_FPV_PATH)/..
SIGMASTAR_MI_VENDOR = $(SIGMASTAR_MI_TOP)/vendor
SIGMASTAR_MI_MPP = $(SIGMASTAR_MI_TOP)/build/sdk/18.06/package/sigmastar/sstar-mpp/files

# Modules come from the XiongMai flash dump, libraries from the vendor SDK. That
# pairing looks wrong and is deliberate: it is the only one that both decodes and
# drives HDMI. The SDK's own modules fail MI_SYS_Init outright.
SIGMASTAR_MI_MODULES = mhal mi_common mi_sys mi_gfx mi_divp mi_disp mi_vdec \
	mi_panel mi_hdmi fbdev

# Only what mi-player and mi-disp-init link. The drop also carries audio, encode,
# IPU, SED and wlan -- about 1.1M this ground station never opens.
SIGMASTAR_MI_LIBS = libmi_sys libmi_common libmi_disp libmi_divp libmi_vdec

define SIGMASTAR_MI_INSTALL_MODULES
	$(INSTALL) -d $(TARGET_DIR)/lib/modules/xm
	$(foreach m,$(SIGMASTAR_MI_MODULES), \
		$(INSTALL) -m 0644 $(SIGMASTAR_MI_VENDOR)/modules/$(m).ko \
			$(TARGET_DIR)/lib/modules/xm/$(m).ko
	)
	# The initramfs is embedded in the kernel's .init section and unpacked into
	# RAM, so the board holds two copies. Debug symbols here panic it.
	$(TARGET_CROSS)strip --strip-debug $(TARGET_DIR)/lib/modules/xm/*.ko
endef

define SIGMASTAR_MI_INSTALL_LIBS
	$(INSTALL) -d $(TARGET_DIR)/usr/lib
	$(foreach l,$(SIGMASTAR_MI_LIBS), \
		$(INSTALL) -m 0755 $(SIGMASTAR_MI_MPP)/glibc/mi_libs/dynamic/$(l).so \
			$(TARGET_DIR)/usr/lib/$(l).so
	)
endef

# The stock /config goes on top of the SDK's rather than replacing files one by
# one: MI_SYSCFG_GetPanelInfo builds its timing table from config/panel/*.ini,
# and without the whole tree every lookup fails and MI_DISP_SetPubAttr dies.
# It also carries the 256MB mmap.ini; the SDK's is for a 64MB board.
define SIGMASTAR_MI_INSTALL_CONFIG
	$(INSTALL) -d $(TARGET_DIR)/config
	cp -a $(SIGMASTAR_MI_MPP)/config/. $(TARGET_DIR)/config/
	cp -a $(SIGMASTAR_MI_VENDOR)/config/. $(TARGET_DIR)/config/
	$(foreach l,dump_config dump_mmap load_config load_mmap, \
		ln -sf config_tool $(TARGET_DIR)/config/$(l)
	)
	rm -f $(TARGET_DIR)/config/misc/*.jpg $(TARGET_DIR)/config/misc/*.mp3
endef

# config_tool is a stock XM binary linked against uClibc, and it has to stay that
# way: the SDK's glibc build emits its config blob in an older layout that XM's
# mi_sys memcpy's into a smaller buffer, oopsing the kernel. So ship the loader
# it needs alongside the glibc one.
define SIGMASTAR_MI_INSTALL_UCLIBC
	$(INSTALL) -d $(TARGET_DIR)/lib
	$(INSTALL) -m 0755 $(SIGMASTAR_MI_VENDOR)/lib/ld-uClibc-1.0.31.so \
		$(TARGET_DIR)/lib/ld-uClibc-1.0.31.so
	$(INSTALL) -m 0755 $(SIGMASTAR_MI_VENDOR)/lib/libuClibc-1.0.31.so \
		$(TARGET_DIR)/lib/libuClibc-1.0.31.so
	ln -sf ld-uClibc-1.0.31.so $(TARGET_DIR)/lib/ld-uClibc.so.1
	ln -sf ld-uClibc.so.1      $(TARGET_DIR)/lib/ld-uClibc.so.0
	ln -sf libuClibc-1.0.31.so $(TARGET_DIR)/lib/libc.so.0
endef

define SIGMASTAR_MI_INSTALL_TARGET_CMDS
	$(SIGMASTAR_MI_INSTALL_MODULES)
	$(SIGMASTAR_MI_INSTALL_LIBS)
	$(SIGMASTAR_MI_INSTALL_CONFIG)
	$(SIGMASTAR_MI_INSTALL_UCLIBC)
endef

define SIGMASTAR_MI_INSTALL_STAGING_CMDS
	$(INSTALL) -d $(STAGING_DIR)/usr/include
	cp -a $(SIGMASTAR_MI_MPP)/glibc/include/. $(STAGING_DIR)/usr/include/
	$(INSTALL) -d $(STAGING_DIR)/usr/lib
	$(foreach l,$(SIGMASTAR_MI_LIBS), \
		$(INSTALL) -m 0755 $(SIGMASTAR_MI_MPP)/glibc/mi_libs/dynamic/$(l).so \
			$(STAGING_DIR)/usr/lib/$(l).so
	)
endef

$(eval $(generic-package))
