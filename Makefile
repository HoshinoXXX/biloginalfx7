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

TWEAK_NAME = B24Probe
B24Probe_FILES = B24Probe.xm BRLog.m
B24Probe_CFLAGS = $(FLAGS)
B24Probe_FRAMEWORKS = Foundation CoreFoundation
# ★ 关键实验：强制链接器把 Objective-C 类和分类从框架 stub 里全部载入
B24Probe_LDFLAGS = -undefined dynamic_lookup -Wl,-ObjC
include $(THEOS_MAKE_PATH)/tweak.mk