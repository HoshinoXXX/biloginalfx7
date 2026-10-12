# 二分第二轮：把 BRStore 和 BRSession 分开，定位到具体文件
export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0
export ADDITIONAL_CFLAGS     = -Wno-deprecated-module-dot-map
export ADDITIONAL_CCFLAGS    = -Wno-deprecated-module-dot-map
export ADDITIONAL_CXXFLAGS   = -Wno-deprecated-module-dot-map
export ADDITIONAL_OBJCFLAGS  = -Wno-deprecated-module-dot-map
export ADDITIONAL_OBJCCFLAGS = -Wno-deprecated-module-dot-map
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = B5Probe B6Probe
B5Probe_FILES = B5Probe.xm BRLog.m BRStore.m
B6Probe_FILES = B6Probe.xm BRLog.m BRSession.m
B5Probe_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map
B6Probe_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map
B5Probe_FRAMEWORKS = Foundation CoreFoundation
B6Probe_FRAMEWORKS = Foundation CoreFoundation
include $(THEOS_MAKE_PATH)/tweak.mk