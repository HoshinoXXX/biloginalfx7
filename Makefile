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

TWEAK_NAME = B7Probe B8Probe B9Probe
B7Probe_FILES = B7Probe.xm BRLog.m BRStore.m
B8Probe_FILES = B8Probe.xm BRLog.m BRSession.m
B9Probe_FILES = B9Probe.xm BRLog.m BRStore.m BRSession.m BRRouter.m BRURLProtocol.m
B7Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER)
B8Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER)
B9Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER)
B7Probe_FRAMEWORKS = Foundation CoreFoundation
B8Probe_FRAMEWORKS = Foundation CoreFoundation
B9Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk