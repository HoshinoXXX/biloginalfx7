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

# ---------------------------------------------------------------- tweak
TWEAK_NAME = QQHelperPort
QQHelperPort_FILES = QQHelperPort.xm
# ARCHS must be repeated per target: adding bundle.mk resets the global value,
# which made the build try arm64 and fail against the simulator-flavoured tbd
# stubs in the 9.3 SDK.
QQHelperPort_ARCHS      = armv7
QQHelperPort_CFLAGS     = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incompatible-pointer-types
QQHelperPort_OBJCFLAGS  = $(WARNFLAGS) $(MINVER)
QQHelperPort_OBJCCFLAGS = $(WARNFLAGS) $(MINVER)
QQHelperPort_FRAMEWORKS = Foundation UIKit
QQHelperPort_LDFLAGS    = -undefined dynamic_lookup

# ------------------------------------------------- preference bundle
BUNDLE_NAME = QQHelperPortPrefs
QQHelperPortPrefs_FILES = QQHelperPortPrefs.m
QQHelperPortPrefs_ARCHS = armv7
QQHelperPortPrefs_INSTALL_PATH = /Library/PreferenceBundles
QQHelperPortPrefs_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER)
QQHelperPortPrefs_FRAMEWORKS = Foundation UIKit
QQHelperPortPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
