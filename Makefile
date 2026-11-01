TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZaloPersistentNotif

ZaloPersistentNotif_FILES = ZaloPersistentNotif.m
ZaloPersistentNotif_CFLAGS = -fobjc-arc -Wno-error
ZaloPersistentNotif_FRAMEWORKS = UIKit Foundation UserNotifications

include $(THEOS_MAKE_PATH)/tweak.mk
