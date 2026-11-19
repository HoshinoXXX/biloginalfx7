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

TWEAK_NAME = QQMin
QQMin_FILES = QQMin.xm
QQMin_ARCHS = armv7
QQMin_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER)
QQMin_OBJCFLAGS = $(WARNFLAGS) $(MINVER)
QQMin_OBJCCFLAGS = $(WARNFLAGS) $(MINVER)
QQMin_FRAMEWORKS = Foundation
QQMin_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk