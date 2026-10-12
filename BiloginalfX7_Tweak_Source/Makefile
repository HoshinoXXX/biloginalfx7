# BiloginalfX7 —— 哔哩哔哩 4.34 复活插件
#
# 编译：make package
#
# ── 关于 SDK 与架构（两个必须写死的点）────────────────────────────
# 1) TARGET 里的 SDK 版本必须显式指定，不能用 latest：
#    iOS 11 起苹果移除了 32 位支持，iPhoneOS11.4 及之后的 SDK 里所有框架
#    都只有 arm64 切片。用 latest（=16.5）链 armv7 时，连 _objc_msgSend /
#    ___CFConstantStringClassReference 这类系统符号都会报
#    "symbol(s) not found for architecture armv7"。
#    9.3 是社区仓库里最后一个完整带 armv7（同时也有 arm64）的 SDK。
#
# 2) iOS 9.3 SDK 里的模块映射用的是旧名字 module.map，新版 clang 把它当成
#    默认错误（-Werror,-Wdeprecated-module-dot-map），必须关掉。
#
# 3) 本版只编 armv7：9.3 / 10.3 的 .tbd 都是 2016 年的旧格式，新 ld 认为
#    「在为 iOS 构建，却链接了为 iOS 模拟器构建的库」——
#    编 armv7 时这只是警告（能过），编 arm64 时变成错误（失败）。
#    arm64 需要另用新 SDK 单独产出后 lipo 合并，留待后续版本。
# ────────────────────────────────────────────────────────────────

export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0

export ADDITIONAL_CFLAGS     = -Wno-deprecated-module-dot-map
export ADDITIONAL_CCFLAGS    = -Wno-deprecated-module-dot-map
export ADDITIONAL_CXXFLAGS   = -Wno-deprecated-module-dot-map
export ADDITIONAL_OBJCFLAGS  = -Wno-deprecated-module-dot-map
export ADDITIONAL_OBJCCFLAGS = -Wno-deprecated-module-dot-map

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BiloginalfX7

BiloginalfX7_FILES = Tweak.xm \
    Core/BRLog.m \
    Core/BRStore.m \
    Core/BRSession.m \
    Core/BRRouter.m \
    Core/BRURLProtocol.m

BiloginalfX7_CFLAGS     = -fobjc-arc -Wno-deprecated-module-dot-map
BiloginalfX7_CCFLAGS    = -Wno-deprecated-module-dot-map
BiloginalfX7_CXXFLAGS   = -Wno-deprecated-module-dot-map
BiloginalfX7_OBJCFLAGS  = -Wno-deprecated-module-dot-map
BiloginalfX7_OBJCCFLAGS = -Wno-deprecated-module-dot-map

BiloginalfX7_FRAMEWORKS = Foundation UIKit CoreFoundation Security
BiloginalfX7_LDFLAGS    = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 bili-universal 2>/dev/null || true"
