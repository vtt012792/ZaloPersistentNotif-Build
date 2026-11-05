ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:16.1
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = Zalo SpringBoard usernotificationsd

TWEAK_NAME = ZaloKeepNotif
ZaloKeepNotif_FILES = Tweak.m
ZaloKeepNotif_FRAMEWORKS = Foundation UIKit UserNotifications
ZaloKeepNotif_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
