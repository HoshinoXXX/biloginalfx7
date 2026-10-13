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

TWEAK_NAME = B16Probe B17Probe
B16Probe_FILES = B16Probe.xm BRLog.m BRSession_h1.m
B17Probe_FILES = B17Probe.xm BRLog.m BRSession_h2.m
B16Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incomplete-implementation -Wno-unused-variable -Wno-unused-const-variable -Wno-unused-function
B17Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incomplete-implementation -Wno-unused-variable -Wno-unused-const-variable -Wno-unused-function
B16Probe_FRAMEWORKS = Foundation CoreFoundation
B17Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk