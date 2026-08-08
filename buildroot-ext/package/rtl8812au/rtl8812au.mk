################################################################################
#
# rtl8812au
#
# The driver's own Makefile drives the kernel build through KSRC rather than the
# usual -C $(LINUX_DIR) M=..., so this is a generic-package that calls it that
# way rather than a kernel-module one.
#
################################################################################

RTL8812AU_VERSION = wfb
RTL8812AU_SITE = $(BR2_EXTERNAL_SSR621Q_FPV_PATH)/../build/rtl8812au
RTL8812AU_SITE_METHOD = local
RTL8812AU_LICENSE = GPL-2.0
RTL8812AU_DEPENDENCIES = linux

define RTL8812AU_BUILD_CMDS
	$(MAKE) -C $(@D) ARCH=arm CROSS_COMPILE=$(TARGET_CROSS) KSRC=$(LINUX_DIR)
endef

define RTL8812AU_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/88XXau_wfb.ko \
		$(TARGET_DIR)/lib/modules/wifi/88XXau_wfb.ko
	$(TARGET_CROSS)strip --strip-debug $(TARGET_DIR)/lib/modules/wifi/88XXau_wfb.ko
endef

$(eval $(generic-package))
