TARGET := iphone:clang:16.5:15.0
ARCHS := arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZaloKeepNotif

ZaloKeepNotif_FILES = Tweak.m
ZaloKeepNotif_CFLAGS = -fobjc-arc -Wno-error -Wno-unused-variable -Wno-unused-function
ZaloKeepNotif_FRAMEWORKS = Foundation UIKit
ZaloKeepNotif_PRIVATE_FRAMEWORKS = UserNotificationsKit BulletinBoard

include $(THEOS_MAKE_PATH)/tweak.mk
