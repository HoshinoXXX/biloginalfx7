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

TWEAK_NAME = B19Probe B20Probe
B19Probe_FILES = B19Probe.xm BRLog.m BRStore.m BRSession.m BRRouter.m
B20Probe_FILES = B20Probe.xm BRLog.m BRStore.m BRSession.m BRRouter.m BRURLProtocol.m
B19Probe_CFLAGS = $(FLAGS)
B20Probe_CFLAGS = $(FLAGS)
B19Probe_FRAMEWORKS = Foundation CoreFoundation
B20Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk