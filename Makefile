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

TWEAK_NAME = B23Probe
B23Probe_FILES = B23Probe.xm BRLog.m
B23Probe_CFLAGS = $(FLAGS)
# ★ 关键：显式链接 CFNetwork（NSURLProtocol 的实现所在）
B23Probe_FRAMEWORKS = Foundation CoreFoundation CFNetwork
include $(THEOS_MAKE_PATH)/tweak.mk