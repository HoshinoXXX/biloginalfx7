export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0
WARNFLAGS = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map
MINVER    = -miphoneos-version-min=7.0
FLAGS     = -fobjc-arc $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CFLAGS     = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CCFLAGS    = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CXXFLAGS   = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_OBJCFLAGS  = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_OBJCCFLAGS = $(WARNFLAGS) $(MINVER)
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = B21Probe B22Probe
B21Probe_FILES = B21Probe.xm BRLog.m
B22Probe_FILES = B22Probe.xm BRLog.m
B21Probe_CFLAGS = $(FLAGS)
B22Probe_CFLAGS = $(FLAGS)
B21Probe_FRAMEWORKS = Foundation CoreFoundation
B22Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk