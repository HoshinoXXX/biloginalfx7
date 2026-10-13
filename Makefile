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

TWEAK_NAME = B10Probe B11Probe
B10Probe_FILES = B10Probe.xm BRLog.m BRSession_min.m
B11Probe_FILES = B11Probe.xm BRLog.m BRSession.m
B10Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incomplete-implementation
B11Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER)
B10Probe_FRAMEWORKS = Foundation CoreFoundation
B11Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk