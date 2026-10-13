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

TWEAK_NAME = B12Probe B13Probe
B12Probe_FILES = B12Probe.xm BRLog.m BRSession_min2.m
B13Probe_FILES = B13Probe.xm BRLog.m BRSession_min3.m
B12Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incomplete-implementation
B13Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incomplete-implementation
B12Probe_FRAMEWORKS = Foundation CoreFoundation
B13Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk