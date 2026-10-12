# BiloginalfX7 —— 阶梯式二分探针
#
# 一次编译产出 4 个复杂度递增的 dylib，全部挂同一个 filter（tv.danmaku.bilianime）：
#
#   B1Probe  只写文件                          ← 最小可加载单元
#   B2Probe  + BRLog                           ← 加日志系统
#   B3Probe  + BRStore + BRSession             ← 加数据层
#   B4Probe  完整（+ BRRouter/BRURLProtocol）   ← 加协议层，并额外链接 UIKit/Security
#
# 每个探针加载后都会往 /tmp/bN.txt 写一行。哪个先不写，就是哪一层的问题。
#
# 同时 B1~B3 只链 Foundation/CoreFoundation，B4 额外链 UIKit/Security ——
# 这样也顺便验证了「多链两个框架导致加载失败」这个假设。

export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0

export ADDITIONAL_CFLAGS     = -Wno-deprecated-module-dot-map
export ADDITIONAL_CCFLAGS    = -Wno-deprecated-module-dot-map
export ADDITIONAL_CXXFLAGS   = -Wno-deprecated-module-dot-map
export ADDITIONAL_OBJCFLAGS  = -Wno-deprecated-module-dot-map
export ADDITIONAL_OBJCCFLAGS = -Wno-deprecated-module-dot-map

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = B1Probe B2Probe B3Probe B4Probe

B1Probe_FILES = B1Probe.xm
B2Probe_FILES = B2Probe.xm BRLog.m
B3Probe_FILES = B3Probe.xm BRLog.m BRStore.m BRSession.m
B4Probe_FILES = B4Probe.xm BRLog.m BRStore.m BRSession.m BRRouter.m BRURLProtocol.m

B1Probe_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map
B2Probe_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map
B3Probe_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map
B4Probe_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map

B1Probe_FRAMEWORKS = Foundation CoreFoundation
B2Probe_FRAMEWORKS = Foundation CoreFoundation
B3Probe_FRAMEWORKS = Foundation CoreFoundation
B4Probe_FRAMEWORKS = Foundation UIKit CoreFoundation Security

# ★ 只有 B4 用 -undefined dynamic_lookup（因为它调用 MSHookMessageEx）；
#   B1~B3 不调用任何 substrate 符号，可以不链接 substrate ——
#   这样也能验证「链接 substrate 是否导致加载失败」。
B1Probe_LDFLAGS = -undefined dynamic_lookup
B2Probe_LDFLAGS = -undefined dynamic_lookup
B3Probe_LDFLAGS = -undefined dynamic_lookup
B4Probe_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
