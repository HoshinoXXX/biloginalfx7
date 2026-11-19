export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0

WARNFLAGS = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map
MINVER    = -miphoneos-version-min=7.0

export ADDITIONAL_CFLAGS     = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CCFLAGS    = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CXXFLAGS   = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_OBJCFLAGS  = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_OBJCCFLAGS = $(WARNFLAGS) $(MINVER)

include $(THEOS)/makefiles/common.mk

# This package TAKES OVER apt.cydiakk.qqhelper: same package name, higher
# version, same dylib name, and it ships the original preference bundle so that
# dpkg's upgrade does not delete the settings panel.
TWEAK_NAME = QQHelper
QQHelper_FILES = QQHelper.xm
QQHelper_ARCHS      = armv7
QQHelper_CFLAGS     = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incompatible-pointer-types
QQHelper_OBJCFLAGS  = $(WARNFLAGS) $(MINVER)
QQHelper_OBJCCFLAGS = $(WARNFLAGS) $(MINVER)
QQHelper_FRAMEWORKS = Foundation UIKit
QQHelper_LDFLAGS    = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

# ------------------------------------------------- preference bundle
BUNDLE_NAME = QQHelperPrefs
QQHelperPrefs_FILES = QQHelperPrefs.m
QQHelperPrefs_ARCHS = armv7
QQHelperPrefs_INSTALL_PATH = /Library/PreferenceBundles
QQHelperPrefs_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER)
QQHelperPrefs_FRAMEWORKS = Foundation UIKit
QQHelperPrefs_LDFLAGS = -undefined dynamic_lookup

$(eval $(call ADDITIONAL_BUNDLE_RULES))
include $(THEOS_MAKE_PATH)/bundle.mk
