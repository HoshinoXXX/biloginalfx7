export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0
WARNFLAGS = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map
MINVER    = -miphoneos-version-min=7.0
FLAGS     = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incomplete-implementation -Wno-unused-variable -Wno-unused-const-variable -Wno-unused-function
export ADDITIONAL_CFLAGS     = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CCFLAGS    = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CXXFLAGS   = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_OBJCFLAGS  = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_OBJCCFLAGS = $(WARNFLAGS) $(MINVER)
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = B18Probe
B18Probe_FILES = B18Probe.xm BRLog.m BRStore.m BRSession.m BRRouter.m BRURLProtocol.m
B18Probe_CFLAGS = $(FLAGS)
B18Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk