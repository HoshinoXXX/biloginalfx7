# BiloginalfX7 —— 哔哩哔哩 4.34 复活插件
#
# Alpha6.3 关键修复：CommonCrypto 改成运行时 dlsym 解析。
#   直接引用 CC_MD5 会在 dylib 里留下未定义符号 _CC_MD5，dyld 在加载瞬间
#   解析不到就让整个 dlopen 失败、dylib 被卸载（现象：dyld: loaded 紧跟
#   dyld: unloaded，构造函数一行都不执行）。详见 BRCrypto.h 顶部说明。
#
# 警告标志：9.3 SDK 的旧式 module.map 在部分 clang 上触发弃用错误，
#   但 macos-14 的新 clang 已移除该警告，再传 -Wno- 它反而报未知选项，
#   所以加 -Wno-unknown-warning-option 兜底。
export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0

WARNFLAGS = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map

export ADDITIONAL_CFLAGS     = $(WARNFLAGS)
export ADDITIONAL_CCFLAGS    = $(WARNFLAGS)
export ADDITIONAL_CXXFLAGS   = $(WARNFLAGS)
export ADDITIONAL_OBJCFLAGS  = $(WARNFLAGS)
export ADDITIONAL_OBJCCFLAGS = $(WARNFLAGS)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BiloginalfX7

BiloginalfX7_FILES = Tweak.xm BRLog.m BRStore.m BRSession.m BRRouter.m BRURLProtocol.m

BiloginalfX7_CFLAGS     = -fobjc-arc $(WARNFLAGS)
BiloginalfX7_CCFLAGS    = $(WARNFLAGS)
BiloginalfX7_CXXFLAGS   = $(WARNFLAGS)
BiloginalfX7_OBJCFLAGS  = $(WARNFLAGS)
BiloginalfX7_OBJCCFLAGS = $(WARNFLAGS)

BiloginalfX7_FRAMEWORKS = Foundation UIKit CoreFoundation Security
BiloginalfX7_LDFLAGS    = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk