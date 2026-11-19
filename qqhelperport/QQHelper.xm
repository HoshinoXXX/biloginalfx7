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
        }

        QQHPLog(@"init done");
    }
}
