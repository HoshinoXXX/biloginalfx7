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

TWEAK_NAME = B14Probe B15Probe
B14Probe_FILES = B14Probe.xm BRLog.m BRSession_g1.m
B15Probe_FILES = B15Probe.xm BRLog.m BRSession_g2.m
B14Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incomplete-implementation -Wno-unused-variable -Wno-unused-const-variable -Wno-unused-function
B15Probe_CFLAGS = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incomplete-implementation -Wno-unused-variable -Wno-unused-const-variable -Wno-unused-function
B14Probe_FRAMEWORKS = Foundation CoreFoundation
B15Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk