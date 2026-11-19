// QQHelper (接管版) —— 直接替换原版 QQHelper，保留它原有的设置面板。
//
// 为什么是这个形态：
//   原版 QQHelper（apt.cydiakk.qqhelper 1.2.6）在 QQ 6.2 上完全没作用 —— 它 hook
//   的类和 QQ 8+ 才对得上。与其另开一个插件，不如直接接管这个包：
//     · 包名仍是 apt.cydiakk.qqhelper，版本升到 1.2.7，dpkg 会原地升级
//     · dylib 仍叫 QQHelper.dylib，占原来那个位子
//     · 设置面板仍是原版那个（/Library/PreferenceBundles/QQHelper.bundle）
//     · 本 dylib 去读它原有的开关 key（fch 等），所以面板看起来完全没变
//
// 功能范围（按用户要求收敛）：
//   1. 撤回按钮         —— 原版没有这个功能，这里加上
//   2. 消息防撤回       —— 对应原面板的 fch，已验证生效
//   3. QQ 空间去广告    —— 对应新增开关 qzonead
//   不做「净化」类功能：QQ 6.2 本身没有头像挂件 / 个性气泡 / 天气那些东西，
//   照搬 QQ 8+ 的屏蔽逻辑没有意义。
//
// 三条硬规则（都是踩过的坑）：
//   1. 绝不 hook 返回结构体的方法。armv7 上 CGRect 走隐藏 sret 指针，
//      声明成 CGRect (id, SEL) 会写坏调用者栈（崩过一次，EXC_BAD_ACCESS 0x1e0）。
//   2. 绝不用「隐藏表格 cell」去掉东西 —— 会让整张消息表塌掉。
//   3. 开关必须早退：if (关闭) { 调原方法; return; }

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>

// ------------------------------------------------------------------ 日志
static void QQHPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[QQH] %@", s);
    NSString *path = @"/tmp/qqhelper.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[[NSString stringWithFormat:@"[QQH] %@\n", s]
                       dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// 读取原版 QQHelper 设置面板里的开关（默认值取自它的 plist）。
// 另外支持 /tmp/qqhelper-off 全局停用，以及 /tmp/qqh-no-<key> 单独停用。
static BOOL QQHOn(NSString *key, BOOL defaultValue) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/tmp/qqhelper-off"]) return NO;
    if (key != nil && [key length] > 0) {
        NSString *tmpName = [@"qqh-no-" stringByAppendingString:key];
        if ([fm fileExistsAtPath:[@"/tmp" stringByAppendingPathComponent:tmpName]])
            return NO;
    }
    // 原面板用 defaults = QQHelper
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (v == nil) {
        NSDictionary *d = [[NSUserDefaults standardUserDefaults]
                           persistentDomainForName:@"QQHelper"];
        v = [d objectForKey:key];
    }
    if (v == nil) return defaultValue;
    return [v boolValue];
}

// ===================== 1. 撤回按钮：两道门禁 =====================
// 门禁一：QQRecallMenuFilter 的 8 个类方法（按消息类型判断）
// 门禁二：QQMessageRecallModule 的 -isInTowMinutes:（两分钟判定）
//         用户反馈「两分钟内的消息也没有撤回」，拦的就是这一层。
// 原版面板没有「撤回按钮」这个开关，所以给一个默认开启、可用 /tmp 关闭的行为。
#define QQH_BOOL_HOOK(NAME)                                                   \
    static BOOL (*orig_##NAME)(Class, SEL, id);                               \
    static BOOL hook_##NAME(Class self, SEL _cmd, id arg) {                   \
        if (!QQHOn(@"recall", YES))                                           \
            return orig_##NAME ? orig_##NAME(self, _cmd, arg) : NO;           \
        QQHPLog(@"[fired] #NAME -> YES");                                     \
        return YES;                                                           \
    }

QQH_BOOL_HOOK(isText)
QQH_BOOL_HOOK(isGroup)
QQH_BOOL_HOOK(isPic)
QQH_BOOL_HOOK(isPtt)
QQH_BOOL_HOOK(isFile)
QQH_BOOL_HOOK(isMarketFace)
QQH_BOOL_HOOK(isSM)
QQH_BOOL_HOOK(isShortVideo)

static BOOL (*orig_isInTowMinutes)(id, SEL, id);
static BOOL hook_isInTowMinutes(id self, SEL _cmd, id msg) {
    if (!QQHOn(@"recall", YES))
        return orig_isInTowMinutes ? orig_isInTowMinutes(self, _cmd, msg) : NO;
    QQHPLog(@"[fired] isInTowMinutes -> YES");
    return YES;
}

// ==================== 2. 防撤回（已验证生效，逻辑不动）====================
// 对应原面板的 fch 开关。
static void (*orig_recvC2C)(id, SEL, void *, int, int, char);
static void hook_recvC2C(id self, SEL _cmd, void *buf, int len, int subcmd, char online) {
    if (!QQHOn(@"fch", NO)) {
        if (orig_recvC2C) orig_recvC2C(self, _cmd, buf, len, subcmd, online);
    } else {
        QQHPLog(@"[fired] recvC2C swallowed");
    }
}

static void (*orig_recvGroup)(id, SEL, void *, unsigned int, char);
static void hook_recvGroup(id self, SEL _cmd, void *buf, unsigned int len, char online) {
    if (!QQHOn(@"fch", NO)) {
        if (orig_recvGroup) orig_recvGroup(self, _cmd, buf, len, online);
    } else {
        QQHPLog(@"[fired] recvGroup swallowed");
    }
}

static void (*orig_recvDiscuss)(id, SEL, void *, unsigned int, char);
static void hook_recvDiscuss(id self, SEL _cmd, void *buf, unsigned int len, char online) {
    if (!QQHOn(@"fch", NO)) {
        if (orig_recvDiscuss) orig_recvDiscuss(self, _cmd, buf, len, online);
    } else {
        QQHPLog(@"[fired] recvDiscuss swallowed");
    }
}

// ==================== 3. QQ 空间去广告 ====================
// 对象回传 / void / CGFloat(float, 走寄存器) 三类，都安全。
static id (*orig_adBannerInit)(id, SEL, CGRect, id);
static id hook_adBannerInit(id self, SEL _cmd, CGRect frame, id unit) {
    if (QQHOn(@"qzonead", YES)) {
        QQHPLog(@"[fired] blocked MQZoneAdBannerView");
        return nil;
    }
    return orig_adBannerInit ? orig_adBannerInit(self, _cmd, frame, unit) : nil;
}

static id (*orig_bannerInit)(id, SEL, CGRect);
static id hook_bannerInit(id self, SEL _cmd, CGRect frame) {
    if (QQHOn(@"qzonead", YES)) {
        QQHPLog(@"[fired] blocked QZoneBannerAdView");
        return nil;
    }
    return orig_bannerInit ? orig_bannerInit(self, _cmd, frame) : nil;
}

static void (*orig_updateBanner)(id, SEL);
static void hook_updateBanner(id self, SEL _cmd) {
    if (!QQHOn(@"qzonead", YES)) {
        if (orig_updateBanner) orig_updateBanner(self, _cmd);
    }
}

static CGFloat (*orig_detailAdHeight)(Class, SEL);
static CGFloat hook_detailAdHeight(Class self, SEL _cmd) {
    if (QQHOn(@"qzonead", YES)) return 0.0f;
    return orig_detailAdHeight ? orig_detailAdHeight(self, _cmd) : 0.0f;
}

// 前向声明（实现在下面的诊断段里）
static void QQHNoteCell(id cell);
static void QQHNoteModel(id model);

// ==================== 3b. QQ空间信息流广告（真正的那个）====================
// 广告 cell 的类名是 QzoneFeedCellGdtAdLR，它自己没有方法，全部继承
// QzoneFeedCell（81 个方法）。所以 hook 基底类的 -layoutFeedView，
// 在里面判断具体类型，只对广告 cell 生效。
// 用 -layoutFeedView（void）而不是 heightForRow，避免动表格结构。
static BOOL QQHIsGdtAdCell(id cell) {
    static Class adCls = Nil;
    static BOOL resolved = NO;
    if (!resolved) {
        adCls = NSClassFromString(@"QzoneFeedCellGdtAdLR");
        resolved = YES;
    }
    if (adCls == Nil || cell == nil) return NO;
    return [cell isKindOfClass:adCls];
}

static void (*orig_layoutFeedView)(id, SEL);
static void hook_layoutFeedView(id self, SEL _cmd) {
    if (orig_layoutFeedView) orig_layoutFeedView(self, _cmd);
    if (!QQHOn(@"qzonead", YES)) return;
    if (!QQHIsGdtAdCell(self)) return;

    QQHPLog(@"[fired] hide QzoneFeedCellGdtAdLR");
    if ([self isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)self;
        [v setHidden:YES];
        // 高度归零，尽量不留空白（表格高度仍由 delegate 决定，可能留一条缝）
        CGRect f = [v frame];
        f.size.height = 0.0f;
        [v setFrame:f];
        // 把所有子视图也藏掉，避免它自绘内容
        for (UIView *sub in [v subviews]) {
            [sub setHidden:YES];
        }
    }
}

// setFeedModel: 时也标记一下，提前隐藏一遍（有些路径不走 layoutFeedView）
static void (*orig_setFeedModel)(id, SEL, id);
static void hook_setFeedModel(id self, SEL _cmd, id model) {
    QQHNoteCell(self);
    QQHNoteModel(model);
    if (orig_setFeedModel) orig_setFeedModel(self, _cmd, model);
    if (!QQHOn(@"qzonead", YES)) return;
    if (!QQHIsGdtAdCell(self)) return;
    QQHPLog(@"[fired] ad cell setFeedModel");
    if ([self isKindOfClass:[UIView class]]) {
        [(UIView *)self setHidden:YES];
    }
}

// ==================== 4. QQ空间图片修复（http -> https）====================
// 用户反馈：QQ空间动态里的图片无法载入。QQ 6.2 的图片 URL 大量是 http:// 的老域名，
// iOS 10 下会被 ATS 或被服务端跳转掉。在请求构造处统一改成 https 即可。
// 只处理图片类 URL，避免动其它请求。
static BOOL QQHLooksLikeImageURL(NSString *s) {
    if ([s length] < 8) return NO;
    if ([s hasPrefix:@"https://"]) return NO;         // 已经是 https
    if (![s hasPrefix:@"http://"] && ![s hasPrefix:@"//"]) return NO;

    // 只认真正的图片/静态资源域名。之前误写了裸 "qq.com"，结果把
    // strategy.beacon.qq.com / jspatch.qq.com 这些埋点接口也改写了。
    static NSArray *hosts = nil;
    if (hosts == nil) {
        hosts = @[@"qpic.cn", @"qlogo.cn", @"gtimg.cn", @"photo.store.qq.com",
                  @"qzonestyle.gtimg.cn", @"qzs.qq.com"];
    }
    for (NSString *h in hosts) {
        if ([s rangeOfString:h].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *QQHFixImageURLString(NSString *s) {
    if ([s hasPrefix:@"//"]) return [@"https:" stringByAppendingString:s];
    if ([s hasPrefix:@"http://"]) {
        return [@"https://" stringByAppendingString:[s substringFromIndex:7]];
    }
    return s;
}

static id (*orig_requestWithURL)(Class, SEL, NSURL *);
static id hook_requestWithURL(Class self, SEL _cmd, NSURL *url) {
    if (QQHOn(@"qzpic", YES) && url != nil) {
        NSString *s = [url absoluteString];
        if (QQHLooksLikeImageURL(s)) {
            NSString *fixed = QQHFixImageURLString(s);
            if (![fixed isEqualToString:s]) {
                NSURL *nu = [NSURL URLWithString:fixed];
                if (nu != nil) {
                    QQHPLog(@"[fired] image url -> %@", fixed);
                    return orig_requestWithURL ? orig_requestWithURL(self, _cmd, nu) : nil;
                }
            }
        }
    }
    return orig_requestWithURL ? orig_requestWithURL(self, _cmd, url) : nil;
}

// ============ 8. 在线显示具体机型 + 网络（onlinemodel，默认关闭）============
// 老版 QQ 的在线状态是「iPhone 6 Plus 4G在线」，6.2 只剩「手机WiFi在线」。
// RichStateModel 的 -getPlainText / -briefText 是文案出口，回传 NSString，安全。

// 机型标识，例如 iPhone6,2
static NSString *QQHMachineID(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *buf = (char *)malloc(size);
    if (buf == NULL) return nil;
    NSString *out = nil;
    if (sysctlbyname("hw.machine", buf, &size, NULL, 0) == 0) {
        out = [NSString stringWithUTF8String:buf];
    }
    free(buf);
    return out;
}

// 把内部标识映射成用户看得懂的名字（只列常见机型，其余原样显示）
static NSString *QQHFriendlyModel(NSString *machine) {
    if ([machine length] == 0) return machine;
    static NSDictionary *map = nil;
    if (map == nil) {
        map = @{
            @"iPhone5,1": @"iPhone 5",  @"iPhone5,2": @"iPhone 5",
            @"iPhone5,3": @"iPhone 5c", @"iPhone5,4": @"iPhone 5c",
            @"iPhone6,1": @"iPhone 5s", @"iPhone6,2": @"iPhone 5s",
            @"iPhone7,1": @"iPhone 6 Plus", @"iPhone7,2": @"iPhone 6",
            @"iPhone8,1": @"iPhone 6s", @"iPhone8,2": @"iPhone 6s Plus",
            @"iPhone8,4": @"iPhone SE",
            @"iPhone9,1": @"iPhone 7",  @"iPhone9,3": @"iPhone 7",
            @"iPhone9,2": @"iPhone 7 Plus", @"iPhone9,4": @"iPhone 7 Plus",
            @"iPhone10,1": @"iPhone 8", @"iPhone10,4": @"iPhone 8",
            @"iPhone10,2": @"iPhone 8 Plus", @"iPhone10,5": @"iPhone 8 Plus",
            @"iPhone10,3": @"iPhone X", @"iPhone10,6": @"iPhone X",
        };
    }
    NSString *nice = [map objectForKey:machine];
    return nice ?: machine;
}

// 当前网络类型
static NSString *QQHNetworkName(void) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || list == NULL) return @"在线";
    BOOL hasWiFi = NO;
    BOOL hasCell = NO;
    for (struct ifaddrs *p = list; p != NULL; p = p->ifa_next) {
        if (p->ifa_addr == NULL) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(p->ifa_name, "en0") == 0) hasWiFi = YES;
        if (strncmp(p->ifa_name, "pdp_ip", 6) == 0) hasCell = YES;
    }
    freeifaddrs(list);
    if (hasWiFi) return @"WiFi在线";
    if (hasCell) return @"4G在线";
    return @"在线";
}

static NSString *QQHOnlineText(void) {
    NSString *model = QQHFriendlyModel(QQHMachineID());
    if ([model length] == 0) model = @"iPhone";
    return [NSString stringWithFormat:@"%@ %@", model, QQHNetworkName()];
}

static id (*orig_richPlainText)(id, SEL);
static id hook_richPlainText(id self, SEL _cmd) {
    if (QQHOn(@"onlinemodel", NO)) {
        NSString *mine = QQHOnlineText();
        QQHPLog(@"[fired] online text -> %@", mine);
        return mine;
    }
    return orig_richPlainText ? orig_richPlainText(self, _cmd) : nil;
}

static id (*orig_richBriefText)(id, SEL);
static id hook_richBriefText(id self, SEL _cmd) {
    if (QQHOn(@"onlinemodel", NO)) return QQHOnlineText();
    return orig_richBriefText ? orig_richBriefText(self, _cmd) : nil;
}

// ============ 7. 365 点赞 / 伪装群管理 / 强开红包（默认关闭）============

// ---- 7.1 伪装 QQ 群管理：wzqqqgl ----
// 成员资料卡里判断「我是不是群主/管理员」的唯一入口。
static BOOL (*orig_isGroupOwnerOrAdmin)(id, SEL);
static BOOL hook_isGroupOwnerOrAdmin(id self, SEL _cmd) {
    if (QQHOn(@"wzqqqgl", NO)) {
        QQHPLog(@"[fired] pretend group owner/admin");
        return YES;
    }
    return orig_isGroupOwnerOrAdmin ? orig_isGroupOwnerOrAdmin(self, _cmd) : NO;
}

// ---- 7.2 365 一键点赞：zan365 ----
// 参数全是标量（zanType:int, andIfNoted:BOOL, increaseNum:int），无结构体，
// 所以即使类型稍有偏差也不会像 CGRect 那样写坏调用者的栈。
static void (*orig_updateZan)(id, SEL, int, int, BOOL, int);
static void hook_updateZan(id self, SEL _cmd, int type, int zanType,
                           BOOL noted, int inc) {
    if (orig_updateZan) orig_updateZan(self, _cmd, type, zanType, noted, inc);
    if (!QQHOn(@"zan365", NO)) return;
    if (noted) return;                     // 已经赞过就不重复
    QQHPLog(@"[fired] 365 auto like scheduled");
    // 走按钮自己的点击链路，最接近用户手动点一下
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            if ([self isKindOfClass:[UIControl class]]) {
                [(UIControl *)self sendActionsForControlEvents:
                    UIControlEventTouchUpInside];
            } else if ([self respondsToSelector:@selector(clickZan)]) {
                [self performSelector:@selector(clickZan)];
            }
        } @catch (NSException *e) {
            QQHPLog(@"zan exception: %@", e);
        }
    });
}

// ---- 7.3 强开红包：redpack ----
// 红包消息气泡拿到数据后，主动触发它自己的「打开」回调。
static void (*orig_setRedEnvelopeInfo)(id, SEL, id);
static void hook_setRedEnvelopeInfo(id self, SEL _cmd, id info) {
    if (orig_setRedEnvelopeInfo) orig_setRedEnvelopeInfo(self, _cmd, info);
    if (!QQHOn(@"redpack", NO)) return;
    QQHPLog(@"[fired] red packet auto open scheduled");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            if ([self respondsToSelector:@selector(openDetailButtonDidTap:)]) {
                [self performSelector:@selector(openDetailButtonDidTap:) withObject:nil];
            }
        } @catch (NSException *e) {
            QQHPLog(@"redpack exception: %@", e);
        }
    });
}

// ============ 6. 净化类功能（全部默认关闭）============
// 这些功能按用户要求「做出来但默认不打开」，用原面板已有的开关 key。

// ---- 6.1 去除天气：tq ----
static id (*orig_weatherInit)(id, SEL);
static id hook_weatherInit(id self, SEL _cmd) {
    id r = orig_weatherInit ? orig_weatherInit(self, _cmd) : nil;
    if (QQHOn(@"tq", NO) && [r isKindOfClass:[UIView class]])
        [(UIView *)r setHidden:YES];
    return r;
}

// ---- 6.2 屏蔽头像挂件：gj ----
static void (*orig_setShouldShowPendant)(id, SEL, BOOL);
static void hook_setShouldShowPendant(id self, SEL _cmd, BOOL show) {
    if (QQHOn(@"gj", NO)) show = NO;
    if (orig_setShouldShowPendant) orig_setShouldShowPendant(self, _cmd, show);
}

static id (*orig_pendantID)(id, SEL);
static id hook_pendantID(id self, SEL _cmd) {
    if (QQHOn(@"gj", NO)) return nil;
    return orig_pendantID ? orig_pendantID(self, _cmd) : nil;
}

// ---- 6.3 屏蔽礼物动画：lw ----
static void (*orig_startAnimation)(id, SEL);
static void hook_startAnimation(id self, SEL _cmd) {
    if (QQHOn(@"lw", NO)) {
        QQHPLog(@"[fired] gift animation skipped");
        return;
    }
    if (orig_startAnimation) orig_startAnimation(self, _cmd);
}

// ---- 6.4 屏蔽表情联想：bqlx ----
static void (*orig_loadFace)(id, SEL, id, BOOL, id);
static void hook_loadFace(id self, SEL _cmd, id face, BOOL cloud, id kw) {
    if (QQHOn(@"bqlx", NO)) return;
    if (orig_loadFace) orig_loadFace(self, _cmd, face, cloud, kw);
}

// ---- 6.5 屏蔽个性字体 / 大小字体：gxzt / dxzt ----
static BOOL QQHFontBlocked(void) {
    return QQHOn(@"gxzt", NO) || QQHOn(@"dxzt", NO);
}

static UIFont *(*orig_aioTextFont)(id, SEL);
static UIFont *hook_aioTextFont(id self, SEL _cmd) {
    if (QQHFontBlocked()) return [UIFont systemFontOfSize:16.0];
    return orig_aioTextFont ? orig_aioTextFont(self, _cmd) : nil;
}

static UIFont *(*orig_aioNickFont)(id, SEL);
static UIFont *hook_aioNickFont(id self, SEL _cmd) {
    if (QQHFontBlocked()) return [UIFont systemFontOfSize:13.0];
    return orig_aioNickFont ? orig_aioNickFont(self, _cmd) : nil;
}

static UIFont *(*orig_aioTimeFont)(id, SEL);
static UIFont *hook_aioTimeFont(id self, SEL _cmd) {
    if (QQHFontBlocked()) return [UIFont systemFontOfSize:11.0];
    return orig_aioTimeFont ? orig_aioTimeFont(self, _cmd) : nil;
}

static UIFont *(*orig_aioVideoFont)(id, SEL);
static UIFont *hook_aioVideoFont(id self, SEL _cmd) {
    if (QQHFontBlocked()) return [UIFont systemFontOfSize:13.0];
    return orig_aioVideoFont ? orig_aioVideoFont(self, _cmd) : nil;
}

// ---- 6.6 屏蔽推荐表情：tjbq ----
static void (*orig_loadEmojiStoreFace)(id, SEL);
static void hook_loadEmojiStoreFace(id self, SEL _cmd) {
    if (QQHOn(@"tjbq", NO)) return;
    if (orig_loadEmojiStoreFace) orig_loadEmojiStoreFace(self, _cmd);
}

// ---- 6.7 屏蔽个性气泡 / 气泡背景：qp / qpbj ----
static BOOL (*orig_hasBubbleResource)(id, SEL, id);
static BOOL hook_hasBubbleResource(id self, SEL _cmd, id arg) {
    if (QQHOn(@"qp", NO) || QQHOn(@"qpbj", NO)) return NO;
    return orig_hasBubbleResource ? orig_hasBubbleResource(self, _cmd, arg) : NO;
}

// ============ 5. QQ 等级修改 / 余额修改（仅本地显示）============
// 原面板已有 Switchqqdjxg / djxg / Switchqqyexg / yexg 四个 key，直接接上。
static NSString *QQHStringPref(NSString *key) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (v == nil) {
        NSDictionary *d = [[NSUserDefaults standardUserDefaults]
                           persistentDomainForName:@"QQHelper"];
        v = [d objectForKey:key];
    }
    if ([v isKindOfClass:[NSString class]]) return v;
    if (v != nil) return [v description];
    return nil;
}

// ---- 等级：QQLevelView -level ----
static int (*orig_levelGetter)(id, SEL);
static int hook_levelGetter(id self, SEL _cmd) {
    if (QQHOn(@"Switchqqdjxg", NO)) {
        NSString *s = QQHStringPref(@"djxg");
        if ([s length] > 0) {
            int v = [s intValue];
            if (v > 0) {
                QQHPLog(@"[fired] level -> %d", v);
                return v;
            }
        }
    }
    return orig_levelGetter ? orig_levelGetter(self, _cmd) : 0;
}

// ---- 余额：PayTool +formatQbBalance: / +formatQdBalance: ----
static id (*orig_formatQb)(Class, SEL, id);
static id hook_formatQb(Class self, SEL _cmd, id raw) {
    if (QQHOn(@"Switchqqyexg", NO)) {
        NSString *s = QQHStringPref(@"yexg");
        if ([s length] > 0) {
            QQHPLog(@"[fired] qbBalance -> %@", s);
            return s;
        }
    }
    return orig_formatQb ? orig_formatQb(self, _cmd, raw) : raw;
}

static id (*orig_formatQd)(Class, SEL, id);
static id hook_formatQd(Class self, SEL _cmd, id raw) {
    if (QQHOn(@"Switchqqyexg", NO)) {
        NSString *s = QQHStringPref(@"yexg");
        if ([s length] > 0) {
            QQHPLog(@"[fired] qdBalance -> %@", s);
            return s;
        }
    }
    return orig_formatQd ? orig_formatQd(self, _cmd, raw) : raw;
}

// ============ 4b. 图片请求的统一入口覆盖 + 诊断日志 ============
// QQ空间图片不走 +[NSURLRequest requestWithURL:]，实测日志里一条 qpic 都没有。
// 这里把 NSURLSession / NSURLConnection / NSMutableURLRequest 的入口全部覆盖，
// 一边改写 http->https，一边把所有图片类 URL 原样打进日志，
// 方便确认到底请求的是哪个地址、卡在哪。
static void QQHNoteImageURL(NSString *s, const char *via) {
    if (s == nil) return;
    if ([s rangeOfString:@"qpic"].location == NSNotFound &&
        [s rangeOfString:@"qlogo"].location == NSNotFound &&
        [s rangeOfString:@"gtimg"].location == NSNotFound &&
        [s rangeOfString:@"photo.store"].location == NSNotFound) return;
    QQHPLog(@"[img] via=%s url=%s", via, [s UTF8String]);
}

static NSURL *QQHFixIfNeeded(NSURL *url, const char *via) {
    if (url == nil) return url;
    NSString *s = [url absoluteString];
    QQHNoteImageURL(s, via);
    if (!QQHOn(@"qzpic", YES)) return url;
    if (!QQHLooksLikeImageURL(s)) return url;
    NSString *fixed = QQHFixImageURLString(s);
    if ([fixed isEqualToString:s]) return url;
    NSURL *nu = [NSURL URLWithString:fixed];
    if (nu == nil) return url;
    QQHPLog(@"[img] rewritten -> %s", [fixed UTF8String]);
    return nu;
}

static id (*orig_dataTaskWithURL)(id, SEL, NSURL *);
static id hook_dataTaskWithURL(id self, SEL _cmd, NSURL *url) {
    NSURL *u = QQHFixIfNeeded(url, "session.url");
    return orig_dataTaskWithURL ? orig_dataTaskWithURL(self, _cmd, u) : nil;
}

static id (*orig_dataTaskWithRequest)(id, SEL, id);
static id hook_dataTaskWithRequest(id self, SEL _cmd, id req) {
    NSURL *u = [req respondsToSelector:@selector(URL)] ? [req URL] : nil;
    QQHNoteImageURL([u absoluteString], "session.req");
    if (QQHOn(@"qzpic", YES) && u != nil &&
        QQHLooksLikeImageURL([u absoluteString])) {
        NSURL *nu = [NSURL URLWithString:QQHFixImageURLString([u absoluteString])];
        if (nu != nil && [req isKindOfClass:[NSMutableURLRequest class]]) {
            [(NSMutableURLRequest *)req setURL:nu];
            QQHPLog(@"[img] req.URL rewritten -> %s", [[nu absoluteString] UTF8String]);
        }
    }
    return orig_dataTaskWithRequest ? orig_dataTaskWithRequest(self, _cmd, req) : nil;
}

static id (*orig_mutableReqInit)(id, SEL, NSURL *);
static id hook_mutableReqInit(id self, SEL _cmd, NSURL *url) {
    NSURL *u = QQHFixIfNeeded(url, "mreq.init");
    return orig_mutableReqInit ? orig_mutableReqInit(self, _cmd, u) : nil;
}

static id (*orig_connInit)(id, SEL, id, id);
static id hook_connInit(id self, SEL _cmd, id req, id delegate) {
    NSURL *u = [req respondsToSelector:@selector(URL)] ? [req URL] : nil;
    QQHNoteImageURL([u absoluteString], "conn.init");
    return orig_connInit ? orig_connInit(self, _cmd, req, delegate) : nil;
}

// ---- NSURLSession 的带 block 变体（SDWebImage 实际走这些）----
static id (*orig_dataTaskWithURLHandler)(id, SEL, NSURL *, id);
static id hook_dataTaskWithURLHandler(id self, SEL _cmd, NSURL *url, id handler) {
    NSURL *u = QQHFixIfNeeded(url, "session.url+cb");
    return orig_dataTaskWithURLHandler
        ? orig_dataTaskWithURLHandler(self, _cmd, u, handler) : nil;
}

static id (*orig_dataTaskWithReqHandler)(id, SEL, id, id);
static id hook_dataTaskWithReqHandler(id self, SEL _cmd, id req, id handler) {
    NSURL *u = [req respondsToSelector:@selector(URL)] ? [req URL] : nil;
    QQHNoteImageURL([u absoluteString], "session.req+cb");
    if (QQHOn(@"qzpic", YES) && u != nil &&
        QQHLooksLikeImageURL([u absoluteString])) {
        NSURL *nu = [NSURL URLWithString:QQHFixImageURLString([u absoluteString])];
        if (nu != nil && [req isKindOfClass:[NSMutableURLRequest class]]) {
            [(NSMutableURLRequest *)req setURL:nu];
        }
    }
    return orig_dataTaskWithReqHandler
        ? orig_dataTaskWithReqHandler(self, _cmd, req, handler) : nil;
}

static id (*orig_downloadTaskWithURL)(id, SEL, NSURL *);
static id hook_downloadTaskWithURL(id self, SEL _cmd, NSURL *url) {
    NSURL *u = QQHFixIfNeeded(url, "session.dl");
    return orig_downloadTaskWithURL ? orig_downloadTaskWithURL(self, _cmd, u) : nil;
}

static id (*orig_downloadTaskWithURLHandler)(id, SEL, NSURL *, id);
static id hook_downloadTaskWithURLHandler(id self, SEL _cmd, NSURL *url, id handler) {
    NSURL *u = QQHFixIfNeeded(url, "session.dl+cb");
    return orig_downloadTaskWithURLHandler
        ? orig_downloadTaskWithURLHandler(self, _cmd, u, handler) : nil;
}

// ---- 等级：-setLevel: 才是真正会被调用的入口 ----
static void (*orig_setLevel)(id, SEL, int);
static void hook_setLevel(id self, SEL _cmd, int lv) {
    if (QQHOn(@"Switchqqdjxg", NO)) {
        NSString *s = QQHStringPref(@"djxg");
        if ([s length] > 0) {
            int v = [s intValue];
            if (v > 0) {
                QQHPLog(@"[fired] setLevel forced %d (was %d)", v, lv);
                lv = v;
            }
        }
    }
    if (orig_setLevel) orig_setLevel(self, _cmd, lv);
}

// ---- 打印 QQHelper 偏好域的实际内容 ----
static void QQHDumpPrefs(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults]
                       persistentDomainForName:@"QQHelper"];
    QQHPLog(@"QQHelper prefs: %@", d);
}

// ---------------- 广告 cell 诊断：打印动态列表里的真实类名 ----------------
static int QQHCellLogCount = 0;
static void QQHNoteCell(id cell) {
    if (QQHCellLogCount >= 40) return;
    QQHCellLogCount++;
    QQHPLog(@"[cell] %@", NSStringFromClass([cell class]));
}

// 广告没法靠 cell 类辨识（实测所有 cell 都叫 QzoneFeedCell），
// 只能看喂进来的数据模型是什么类型。
static int QQHModelLogCount = 0;
static void QQHNoteModel(id model) {
    if (model == nil) return;
    if (QQHModelLogCount >= 60) return;
    QQHModelLogCount++;
    QQHPLog(@"[model] %@", NSStringFromClass([model class]));
}

// ============================ 安装辅助 ============================
static void QQHSwizzle(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    if (cls == Nil || sel == NULL) return;

    Method m = class_getClassMethod(cls, sel);
    const char *scope = "class";
    if (m == NULL) {
        m = class_getInstanceMethod(cls, sel);
        scope = "instance";
    }
    if (m == NULL) {
        QQHPLog(@"NOT FOUND  %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    QQHPLog(@"hook %-8s %@ %@  enc=%s", scope, NSStringFromClass(cls),
            NSStringFromSelector(sel), method_getTypeEncoding(m) ?: "?");
    *oldImp = (IMP)method_getImplementation(m);
    method_setImplementation(m, newImp);
}

__attribute__((constructor))
static void QQHInit(void) {
    @autoreleasepool {
        QQHPLog(@"loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/qqhelper-off"]) {
            QQHPLog(@"globally disabled by /tmp/qqhelper-off");
            return;
        }

        // 1. 撤回按钮
        Class filter = NSClassFromString(@"QQRecallMenuFilter");
        if (filter != Nil) {
            QQHSwizzle(filter, @selector(isTextNeedShowMenuRecall:), (IMP)&hook_isText, (IMP *)&orig_isText);
            QQHSwizzle(filter, @selector(isGroupMessageNeedShowMenuRecall:), (IMP)&hook_isGroup, (IMP *)&orig_isGroup);
            QQHSwizzle(filter, @selector(isQQPicMessageNeedShowMenuRecall:), (IMP)&hook_isPic, (IMP *)&orig_isPic);
            QQHSwizzle(filter, @selector(isQQPttMessageNeedShowMenuRecall:), (IMP)&hook_isPtt, (IMP *)&orig_isPtt);
            QQHSwizzle(filter, @selector(isFileNeedShowMenuRecall:), (IMP)&hook_isFile, (IMP *)&orig_isFile);
            QQHSwizzle(filter, @selector(isMarketFaceNeedShowMenuRecall:), (IMP)&hook_isMarketFace, (IMP *)&orig_isMarketFace);
            QQHSwizzle(filter, @selector(isQQSMMessageNeedShowMenuRecall:), (IMP)&hook_isSM, (IMP *)&orig_isSM);
            QQHSwizzle(filter, @selector(isQQRichShortVideoMessageNeedShowMenuRecall:), (IMP)&hook_isShortVideo, (IMP *)&orig_isShortVideo);
        } else {
            QQHPLog(@"QQRecallMenuFilter missing");
        }

        Class recall = NSClassFromString(@"QQMessageRecallModule");
        if (recall != Nil) {
            QQHSwizzle(recall, @selector(isInTowMinutes:), (IMP)&hook_isInTowMinutes,
                       (IMP *)&orig_isInTowMinutes);
            // 2. 防撤回
            QQHSwizzle(recall, @selector(recvC2CRecallNotify:bufferLen:subcmd:isOnline:),
                       (IMP)&hook_recvC2C, (IMP *)&orig_recvC2C);
            QQHSwizzle(recall, @selector(recvGroupRecallNotify:bufferLen:isOnline:),
                       (IMP)&hook_recvGroup, (IMP *)&orig_recvGroup);
            QQHSwizzle(recall, @selector(recvDiscussRecallNotify:bufferLen:isOnline:),
                       (IMP)&hook_recvDiscuss, (IMP *)&orig_recvDiscuss);
        }

        // 3. QQ 空间去广告
        {
            Class c = NSClassFromString(@"MQZoneAdBannerView");
            if (c != Nil)
                QQHSwizzle(c, @selector(initWithFrame:adBannerUnit:),
                           (IMP)&hook_adBannerInit, (IMP *)&orig_adBannerInit);

            c = NSClassFromString(@"QZoneBannerAdView");
            if (c != Nil) {
                QQHSwizzle(c, @selector(initWithFrame:),
                           (IMP)&hook_bannerInit, (IMP *)&orig_bannerInit);
                QQHSwizzle(c, @selector(updateBanner),
                           (IMP)&hook_updateBanner, (IMP *)&orig_updateBanner);
            }

            c = NSClassFromString(@"MQZoneDetailAdBannerCell");
            if (c != Nil)
                QQHSwizzle(c, @selector(heightForCell),
                           (IMP)&hook_detailAdHeight, (IMP *)&orig_detailAdHeight);

            // 真正的那个信息流广告：hook 基底类 QzoneFeedCell
            c = NSClassFromString(@"QzoneFeedCell");
            if (c != Nil) {
                QQHSwizzle(c, @selector(layoutFeedView),
                           (IMP)&hook_layoutFeedView, (IMP *)&orig_layoutFeedView);
                QQHSwizzle(c, @selector(setFeedModel:),
                           (IMP)&hook_setFeedModel, (IMP *)&orig_setFeedModel);
            } else {
                QQHPLog(@"QzoneFeedCell missing");
            }
        }

        // 4. QQ空间图片修复
        {
            Class nsurlreq = NSClassFromString(@"NSURLRequest");
            if (nsurlreq != Nil) {
                Class meta = object_getClass(nsurlreq);
                if (meta != Nil) {
                    Method m = class_getClassMethod(nsurlreq,
                                                    @selector(requestWithURL:));
                    if (m != NULL) {
                        QQHPLog(@"hook class    NSURLRequest requestWithURL:  enc=%s",
                                method_getTypeEncoding(m) ?: "?");
                        orig_requestWithURL = (id (*)(Class, SEL, NSURL *))
                            method_getImplementation(m);
                        method_setImplementation(m, (IMP)&hook_requestWithURL);
                    } else {
                        QQHPLog(@"NSURLRequest requestWithURL: not found");
                    }
                }
            }
        }

        // 4b. 图片请求的其它入口（QQ空间图片不走 requestWithURL:）
        {
            Class sess = NSClassFromString(@"NSURLSession");
            if (sess != Nil) {
                QQHSwizzle(sess, @selector(dataTaskWithURL:),
                           (IMP)&hook_dataTaskWithURL, (IMP *)&orig_dataTaskWithURL);
                QQHSwizzle(sess, @selector(dataTaskWithRequest:),
                           (IMP)&hook_dataTaskWithRequest, (IMP *)&orig_dataTaskWithRequest);
            }
            Class mreq = NSClassFromString(@"NSMutableURLRequest");
            if (mreq != Nil) {
                QQHSwizzle(mreq, @selector(initWithURL:),
                           (IMP)&hook_mutableReqInit, (IMP *)&orig_mutableReqInit);
            }
            Class conn = NSClassFromString(@"NSURLConnection");
            if (conn != Nil) {
                QQHSwizzle(conn, @selector(initWithRequest:delegate:),
                           (IMP)&hook_connInit, (IMP *)&orig_connInit);
            }

            // 带 block 的变体：SDWebImage 实际用的是这些
            if (sess != Nil) {
                QQHSwizzle(sess, @selector(dataTaskWithURL:completionHandler:),
                           (IMP)&hook_dataTaskWithURLHandler,
                           (IMP *)&orig_dataTaskWithURLHandler);
                QQHSwizzle(sess, @selector(dataTaskWithRequest:completionHandler:),
                           (IMP)&hook_dataTaskWithReqHandler,
                           (IMP *)&orig_dataTaskWithReqHandler);
                QQHSwizzle(sess, @selector(downloadTaskWithURL:),
                           (IMP)&hook_downloadTaskWithURL,
                           (IMP *)&orig_downloadTaskWithURL);
                QQHSwizzle(sess, @selector(downloadTaskWithURL:completionHandler:),
                           (IMP)&hook_downloadTaskWithURLHandler,
                           (IMP *)&orig_downloadTaskWithURLHandler);
            }
        }

        // 5. 等级修改 / 余额修改
        {
            Class lv = NSClassFromString(@"QQLevelView");
            if (lv != Nil) {
                QQHSwizzle(lv, @selector(level),
                           (IMP)&hook_levelGetter, (IMP *)&orig_levelGetter);
                QQHSwizzle(lv, @selector(setLevel:),
                           (IMP)&hook_setLevel, (IMP *)&orig_setLevel);
            }

            Class pay = NSClassFromString(@"PayTool");
            if (pay != Nil) {
                QQHSwizzle(pay, @selector(formatQbBalance:),
                           (IMP)&hook_formatQb, (IMP *)&orig_formatQb);
                QQHSwizzle(pay, @selector(formatQdBalance:),
                           (IMP)&hook_formatQd, (IMP *)&orig_formatQd);
            } else {
                QQHPLog(@"PayTool missing");
            }
        }

        // 6. 净化类功能（默认关闭）
        {
            Class c = NSClassFromString(@"QQWeatherView");
            if (c != Nil)
                QQHSwizzle(c, @selector(init), (IMP)&hook_weatherInit, (IMP *)&orig_weatherInit);

            c = NSClassFromString(@"QQAvatarView");
            if (c != Nil) {
                QQHSwizzle(c, @selector(setShouldShowAvatarPendant:),
                           (IMP)&hook_setShouldShowPendant,
                           (IMP *)&orig_setShouldShowPendant);
                QQHSwizzle(c, @selector(avatarPendantID),
                           (IMP)&hook_pendantID, (IMP *)&orig_pendantID);
            }

            c = NSClassFromString(@"QQGroupDeliverGiftAnimationManager");
            if (c != Nil)
                QQHSwizzle(c, @selector(startAnimation),
                           (IMP)&hook_startAnimation, (IMP *)&orig_startAnimation);

            c = NSClassFromString(@"QQFaceAssociateFrameView");
            if (c != Nil)
                QQHSwizzle(c, @selector(loadFace:hasCloudEmoji:keywords:),
                           (IMP)&hook_loadFace, (IMP *)&orig_loadFace);

            c = NSClassFromString(@"QQAIOFontManager");
            if (c != Nil) {
                QQHSwizzle(c, @selector(aioTextFont), (IMP)&hook_aioTextFont, (IMP *)&orig_aioTextFont);
                QQHSwizzle(c, @selector(aioNickFont), (IMP)&hook_aioNickFont, (IMP *)&orig_aioNickFont);
                QQHSwizzle(c, @selector(aioTimeFont), (IMP)&hook_aioTimeFont, (IMP *)&orig_aioTimeFont);
                QQHSwizzle(c, @selector(aioVideoFont), (IMP)&hook_aioVideoFont, (IMP *)&orig_aioVideoFont);
            }

            c = NSClassFromString(@"QQFacePanelController");
            if (c != Nil)
                QQHSwizzle(c, @selector(loadEmojiStoreFace),
                           (IMP)&hook_loadEmojiStoreFace, (IMP *)&orig_loadEmojiStoreFace);

            c = NSClassFromString(@"BubbleBgManager");
            if (c != Nil)
                QQHSwizzle(c, @selector(hasBubbleResource:),
                           (IMP)&hook_hasBubbleResource, (IMP *)&orig_hasBubbleResource);
        }

        // 7. 365 点赞 / 伪装群管理 / 强开红包
        {
            Class vc = NSClassFromString(@"QQGroupMemberCardViewController");
            if (vc != Nil)
                QQHSwizzle(vc, @selector(isGroupOwnerOrAdministrator:),
                           (IMP)&hook_isGroupOwnerOrAdmin,
                           (IMP *)&orig_isGroupOwnerOrAdmin);

            Class zan = NSClassFromString(@"UserSummaryZanButton");
            if (zan != Nil)
                QQHSwizzle(zan, @selector(updateZanType:zanType:andIfNoted:increaseNum:),
                           (IMP)&hook_updateZan, (IMP *)&orig_updateZan);

            Class rp = NSClassFromString(@"QQWalletRedEnvelopeAIOMsgView");
            if (rp != Nil)
                QQHSwizzle(rp, @selector(setRedEnvelopeInfo:),
                           (IMP)&hook_setRedEnvelopeInfo,
                           (IMP *)&orig_setRedEnvelopeInfo);
        }

        // 8. 在线显示机型 + 网络
        {
            Class rs = NSClassFromString(@"RichStateModel");
            if (rs != Nil) {
                QQHSwizzle(rs, @selector(getPlainText),
                           (IMP)&hook_richPlainText, (IMP *)&orig_richPlainText);
                QQHSwizzle(rs, @selector(briefText),
                           (IMP)&hook_richBriefText, (IMP *)&orig_richBriefText);
            } else {
                QQHPLog(@"RichStateModel missing");
            }
            // 设备名与网络只在开关打开时才算，避免每次启动多做无用功
            if (QQHOn(@"onlinemodel", NO))
                QQHPLog(@"online model preview: %@", QQHOnlineText());
        }

        QQHDumpPrefs();

        QQHPLog(@"init done");
    }
}
