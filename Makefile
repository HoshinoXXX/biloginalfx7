# 二分第二轮：把 BRStore 和 BRSession 分开，定位到具体文件
#
# 关于 -Wno-deprecated-module-dot-map：
#   9.3 SDK 里用的是旧式 module.map，某些版本的 clang 会把它当 default-error。
#   但 macos-14 的新 clang 已经移除了这个警告 —— 此时再传 -Wno- 它，
#   反而触发 -Wunknown-warning-option 错误。
#   所以同时加上 -Wno-unknown-warning-option 兜底：两个版本都能编。
export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0

export ADDITIONAL_CFLAGS     = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map
export ADDITIONAL_CCFLAGS    = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map
export ADDITIONAL_CXXFLAGS   = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map
export ADDITIONAL_OBJCFLAGS  = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map
export ADDITIONAL_OBJCCFLAGS = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = B5Probe B6Probe

B5Probe_FILES = B5Probe.xm BRLog.m BRStore.m
B6Probe_FILES = B6Probe.xm BRLog.m BRSession.m

WARNFLAGS = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map

B5Probe_CFLAGS = -fobjc-arc $(WARNFLAGS)
B6Probe_CFLAGS = -fobjc-arc $(WARNFLAGS)
B5Probe_CCFLAGS = $(WARNFLAGS)
B6Probe_CCFLAGS = $(WARNFLAGS)
B5Probe_OBJCFLAGS = $(WARNFLAGS)
B6Probe_OBJCFLAGS = $(WARNFLAGS)
B5Probe_OBJCCFLAGS = $(WARNFLAGS)
B6Probe_OBJCCFLAGS = $(WARNFLAGS)

B5Probe_FRAMEWORKS = Foundation CoreFoundation
B6Probe_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk