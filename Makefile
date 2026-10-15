# BiloginalfX7 —— 哔哩哔哩 4.34 复活插件
#
# ── 三个「未定义符号导致 dlopen 失败」的坑（都已在下面处理）──────
#  1) CC_MD5（CommonCrypto）      → 改用 BRCrypto.h 的 dlsym 垫片
#  2) BRIsBiliHost 缺 extern "C"  → 已在 BRURLProtocol.h 补上
#  3) ARC 生成 objc_retainAutoreleaseReturnValue 这类新式运行时函数
#     → 用 -miphoneos-version-min=7.0 让 clang 明确按 iOS 7 生成代码，
#       否则它会以为目标是新版 iOS，生成 iOS 7 早期版本没有的符号。
#
#  这三个的后果完全一样：dyld 在加载瞬间解析不到 → dlopen 返回 NULL
#  → SubstrateLoader 卸载 dylib → 构造函数一行都不执行
#  （现象：dyld: loaded 紧跟 dyld: unloaded，无崩溃日志）
# ────────────────────────────────────────────────────────────────
export ARCHS = armv7
export TARGET = iphone:clang:9.3:7.0

WARNFLAGS = -Wno-unknown-warning-option -Wno-deprecated-module-dot-map
MINVER    = -miphoneos-version-min=7.0

export ADDITIONAL_CFLAGS     = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CCFLAGS    = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_CXXFLAGS   = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_OBJCFLAGS  = $(WARNFLAGS) $(MINVER)
export ADDITIONAL_OBJCCFLAGS = $(WARNFLAGS) $(MINVER)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BiloginalfX7

BiloginalfX7_FILES = BRLogin.m Tweak.xm BRLog.m BRStore.m BRSession.m BRRouter.m BRURLProtocol.m BRZlib.m

BiloginalfX7_CFLAGS     = -fobjc-arc $(WARNFLAGS) $(MINVER) -Wno-incompatible-pointer-types -Wno-unused-function -Wno-unused-variable
BiloginalfX7_CCFLAGS    = $(WARNFLAGS) $(MINVER)
BiloginalfX7_CXXFLAGS   = $(WARNFLAGS) $(MINVER)
BiloginalfX7_OBJCFLAGS  = $(WARNFLAGS) $(MINVER)
BiloginalfX7_OBJCCFLAGS = $(WARNFLAGS) $(MINVER)

BiloginalfX7_FRAMEWORKS = Foundation UIKit CoreFoundation Security
BiloginalfX7_LDFLAGS    = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk