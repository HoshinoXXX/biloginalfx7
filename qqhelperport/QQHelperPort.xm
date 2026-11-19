// QQHelperPort - QQHelper 的完整功能移植到 QQ 6.2
//
// 依据：从运行中的 QQ 6.2（iPhone 5c / iOS 10.3.4）dump 出的 ObjC 运行时清单
// （24,245 个类，3,606 个类的方法表）。
//
// ============================ 三条铁律 ============================
// 1. 绝不 hook 返回结构体的方法。armv7 上 16 字节的 CGRect 走隐藏 sret 指针，
//    声明成 `CGRect (id, SEL)` 会写坏调用者栈 —— 已经因此崩过一次
//    （EXC_BAD_ACCESS at 0x1e0）。用 setShouldShowAvatarPendant: /
//    avatarPendantID 这类 void / 对象 方法来达成同样效果。
//    注意：CGFloat(=float) 在 armv7 走寄存器返回，是安全的。
// 2. 绝不用「隐藏表格 cell」来去掉东西。隐藏 QQAIOTimeCell（聊天分组表头）
//    会让整个消息表塌掉，一条消息都不显示。
// 3. 开关必须「早退」：if (QQHPOff(name)) { 调原方法; return; }
//    第一版写成 !QQHPOn(name) 包裹动作，导致开关形同虚设。
// ==================================================================
//
// 开关（建立对应文件即关闭该功能）：
//   /tmp/qqhp-off             全部
//   /tmp/qqhp-no-recall       撤回按钮
//   /tmp/qqhp-no-antirevoke   防撤回
//   /tmp/qqhp-no-pendant      头像挂件
//   /tmp/qqhp-no-font         个性/大小字体
//   /tmp/qqhp-no-weather      天气
//   /tmp/qqhp-no-gift         礼物动画
//   /tmp/qqhp-no-faceassoc    表情联想
//   /tmp/qqhp-no-facestore    推荐表情
//   /tmp/qqhp-no-qzonead      QQ空间去广告

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// ------------------------------------------------------------------ 日志
static void QQHPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[QQHP] %@", s);
    NSString *path = @"/tmp/qqhp.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [[NSFileManager defaultManager] createFileAtPath:path
                                                contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[[NSString stringWithFormat:@"[QQHP] %@\n", s]
                       dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static BOOL QQHPOff(NSString *switchName) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/qqhp-off"]) return YES;
    return [[NSFileManager defaultManager]
            fileExistsAtPath:[@"/tmp" stringByAppendingPathComponent:switchName]];
}

// ===================== 1. 撤回按钮：两道门禁 =====================
// 门禁一：QQRecallMenuFilter 的 8 个类方法（按消息类型判断）
// 门禁二：QQMessageRecallModule 的 -isInTowMinutes:（两分钟判定）
//          这才是「消息在两分钟内却看不到撤回」的真正原因。
#define QQHP_BOOL_HOOK(NAME)                                                  \
    static BOOL (*orig_##NAME)(Class, SEL, id);                               \
    static BOOL hook_##NAME(Class self, SEL _cmd, id arg) {                   \
        if (QQHPOff(@"qqhp-no-recall"))                                       \
            return orig_##NAME ? orig_##NAME(self, _cmd, arg) : NO;           \
        QQHPLog(@"[fired] #NAME -> YES");                                     \
        return YES;                                                           \
    }

QQHP_BOOL_HOOK(isText)
QQHP_BOOL_HOOK(isGroup)
QQHP_BOOL_HOOK(isPic)
QQHP_BOOL_HOOK(isPtt)
QQHP_BOOL_HOOK(isFile)
QQHP_BOOL_HOOK(isMarketFace)
QQHP_BOOL_HOOK(isSM)
QQHP_BOOL_HOOK(isShortVideo)

// 两分钟判定
static BOOL (*orig_isInTowMinutes)(id, SEL, id);
static BOOL hook_isInTowMinutes(id self, SEL _cmd, id msg) {
    if (QQHPOff(@"qqhp-no-recall"))
        return orig_isInTowMinutes ? orig_isInTowMinutes(self, _cmd, msg) : NO;
    QQHPLog(@"[fired] isInTowMinutes -> YES");
    return YES;
}

// ==================== 2. 防撤回 ====================
static void (*orig_recvC2C)(id, SEL, void *, int, int, char);
static void hook_recvC2C(id self, SEL _cmd, void *buf, int len, int subcmd, char online) {
    if (QQHPOff(@"qqhp-no-antirevoke")) {
        if (orig_recvC2C) orig_recvC2C(self, _cmd, buf, len, subcmd, online);
    } else {
        QQHPLog(@"[fired] recvC2C swallowed");
    }
}

static void (*orig_recvGroup)(id, SEL, void *, unsigned int, char);
static void hook_recvGroup(id self, SEL _cmd, void *buf, unsigned int len, char online) {
    if (QQHPOff(@"qqhp-no-antirevoke")) {
        if (orig_recvGroup) orig_recvGroup(self, _cmd, buf, len, online);
    } else {
        QQHPLog(@"[fired] recvGroup swallowed");
    }
}

static void (*orig_recvDiscuss)(id, SEL, void *, unsigned int, char);
static void hook_recvDiscuss(id self, SEL _cmd, void *buf, unsigned int len, char online) {
    if (QQHPOff(@"qqhp-no-antirevoke")) {
        if (orig_recvDiscuss) orig_recvDiscuss(self, _cmd, buf, len, online);
    } else {
        QQHPLog(@"[fired] recvDiscuss swallowed");
    }
}

// ================== 3. 头像挂件 ==================
static void (*orig_setShouldShowPendant)(id, SEL, BOOL);
static void hook_setShouldShowPendant(id self, SEL _cmd, BOOL show) {
    if (QQHPOff(@"qqhp-no-pendant")) {
        if (orig_setShouldShowPendant) orig_setShouldShowPendant(self, _cmd, show);
        return;
    }
    if (orig_setShouldShowPendant) orig_setShouldShowPendant(self, _cmd, NO);
}

static id (*orig_pendantID)(id, SEL);
static id hook_pendantID(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-pendant"))
        return orig_pendantID ? orig_pendantID(self, _cmd) : nil;
    return nil;
}

static BOOL (*orig_shouldShowPendant)(id, SEL);
static BOOL hook_shouldShowPendant(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-pendant"))
        return orig_shouldShowPendant ? orig_shouldShowPendant(self, _cmd) : NO;
    return NO;
}

// ================== 4. 个性 / 大小字体 ==================
static UIFont *QQHPSysFont(CGFloat size) {
    return [UIFont systemFontOfSize:(size > 0 ? size : 16.0)];
}

static UIFont *(*orig_aioTextFont)(id, SEL);
static UIFont *hook_aioTextFont(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-font")) return orig_aioTextFont ? orig_aioTextFont(self, _cmd) : nil;
    return QQHPSysFont(16.0);
}

static UIFont *(*orig_aioNickFont)(id, SEL);
static UIFont *hook_aioNickFont(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-font")) return orig_aioNickFont ? orig_aioNickFont(self, _cmd) : nil;
    return QQHPSysFont(13.0);
}

static UIFont *(*orig_aioTimeFont)(id, SEL);
static UIFont *hook_aioTimeFont(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-font")) return orig_aioTimeFont ? orig_aioTimeFont(self, _cmd) : nil;
    return QQHPSysFont(11.0);
}

static UIFont *(*orig_aioVideoFont)(id, SEL);
static UIFont *hook_aioVideoFont(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-font")) return orig_aioVideoFont ? orig_aioVideoFont(self, _cmd) : nil;
    return QQHPSysFont(13.0);
}

// ====================== 5. 天气 ======================
static id (*orig_weatherInit)(id, SEL);
static id hook_weatherInit(id self, SEL _cmd) {
    id r = orig_weatherInit ? orig_weatherInit(self, _cmd) : nil;
    if (!QQHPOff(@"qqhp-no-weather") && [r isKindOfClass:[UIView class]])
        [(UIView *)r setHidden:YES];
    return r;
}

// ============ 6. 礼物动画 ============
static void (*orig_startAnimation)(id, SEL);
static void hook_startAnimation(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-gift")) {
        if (orig_startAnimation) orig_startAnimation(self, _cmd);
    }
}

// ============ 7. 表情联想 ============
static void (*orig_loadFace)(id, SEL, id, BOOL, id);
static void hook_loadFace(id self, SEL _cmd, id face, BOOL cloud, id keywords) {
    if (QQHPOff(@"qqhp-no-faceassoc")) {
        if (orig_loadFace) orig_loadFace(self, _cmd, face, cloud, keywords);
    }
}

// ============ 8. 推荐表情 ============
static void (*orig_loadEmojiStoreFace)(id, SEL);
static void hook_loadEmojiStoreFace(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-facestore")) {
        if (orig_loadEmojiStoreFace) orig_loadEmojiStoreFace(self, _cmd);
    }
}

// ============ 9. QQ空间去广告 ============
// 做法：让广告 view/cell 创建时返回 nil（对象回传，安全），
//       并把 banner 的高度判定改成 0（CGFloat=float，寄存器回传，安全）。
static id (*orig_adBannerInit)(id, SEL, CGRect, id);
static id hook_adBannerInit(id self, SEL _cmd, CGRect frame, id unit) {
    if (!QQHPOff(@"qqhp-no-qzonead")) {
        QQHPLog(@"[fired] blocked MQZoneAdBannerView init");
        return nil;
    }
    return orig_adBannerInit ? orig_adBannerInit(self, _cmd, frame, unit) : nil;
}

static id (*orig_bannerInit)(id, SEL, CGRect);
static id hook_bannerInit(id self, SEL _cmd, CGRect frame) {
    if (!QQHPOff(@"qqhp-no-qzonead")) {
        QQHPLog(@"[fired] blocked QZoneBannerAdView init");
        return nil;
    }
    return orig_bannerInit ? orig_bannerInit(self, _cmd, frame) : nil;
}

static void (*orig_updateBanner)(id, SEL);
static void hook_updateBanner(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-qzonead")) {
        if (orig_updateBanner) orig_updateBanner(self, _cmd);
    }
}

static CGFloat (*orig_detailAdHeight)(Class, SEL);
static CGFloat hook_detailAdHeight(Class self, SEL _cmd) {
    if (!QQHPOff(@"qqhp-no-qzonead")) return 0.0f;
    return orig_detailAdHeight ? orig_detailAdHeight(self, _cmd) : 0.0f;
}

// ============================ 安装辅助 ============================
static void QQHPSwizzle(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
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
static void QQHPInit(void) {
    @autoreleasepool {
        QQHPLog(@"loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/qqhp-off"]) {
            QQHPLog(@"globally disabled by /tmp/qqhp-off");
            return;
        }

        // 1. 撤回：类型门禁
        Class filter = NSClassFromString(@"QQRecallMenuFilter");
        if (filter != Nil) {
            QQHPSwizzle(filter, @selector(isTextNeedShowMenuRecall:), (IMP)&hook_isText, (IMP *)&orig_isText);
            QQHPSwizzle(filter, @selector(isGroupMessageNeedShowMenuRecall:), (IMP)&hook_isGroup, (IMP *)&orig_isGroup);
            QQHPSwizzle(filter, @selector(isQQPicMessageNeedShowMenuRecall:), (IMP)&hook_isPic, (IMP *)&orig_isPic);
            QQHPSwizzle(filter, @selector(isQQPttMessageNeedShowMenuRecall:), (IMP)&hook_isPtt, (IMP *)&orig_isPtt);
            QQHPSwizzle(filter, @selector(isFileNeedShowMenuRecall:), (IMP)&hook_isFile, (IMP *)&orig_isFile);
            QQHPSwizzle(filter, @selector(isMarketFaceNeedShowMenuRecall:), (IMP)&hook_isMarketFace, (IMP *)&orig_isMarketFace);
            QQHPSwizzle(filter, @selector(isQQSMMessageNeedShowMenuRecall:), (IMP)&hook_isSM, (IMP *)&orig_isSM);
            QQHPSwizzle(filter, @selector(isQQRichShortVideoMessageNeedShowMenuRecall:), (IMP)&hook_isShortVideo, (IMP *)&orig_isShortVideo);
        } else {
            QQHPLog(@"QQRecallMenuFilter missing");
        }

        // 1b. 撤回：两分钟门禁
        {
            Class c = NSClassFromString(@"QQMessageRecallModule");
            if (c != Nil)
                QQHPSwizzle(c, @selector(isInTowMinutes:), (IMP)&hook_isInTowMinutes,
                            (IMP *)&orig_isInTowMinutes);
        }

        // 2. 防撤回
        {
            Class c = NSClassFromString(@"QQMessageRecallModule");
            if (c != Nil) {
                QQHPSwizzle(c, @selector(recvC2CRecallNotify:bufferLen:subcmd:isOnline:),
                            (IMP)&hook_recvC2C, (IMP *)&orig_recvC2C);
                QQHPSwizzle(c, @selector(recvGroupRecallNotify:bufferLen:isOnline:),
                            (IMP)&hook_recvGroup, (IMP *)&orig_recvGroup);
                QQHPSwizzle(c, @selector(recvDiscussRecallNotify:bufferLen:isOnline:),
                            (IMP)&hook_recvDiscuss, (IMP *)&orig_recvDiscuss);
            }
        }

        // 3. 头像挂件
        {
            Class c = NSClassFromString(@"QQAvatarView");
            if (c != Nil) {
                QQHPSwizzle(c, @selector(setShouldShowAvatarPendant:),
                            (IMP)&hook_setShouldShowPendant, (IMP *)&orig_setShouldShowPendant);
                QQHPSwizzle(c, @selector(avatarPendantID),
                            (IMP)&hook_pendantID, (IMP *)&orig_pendantID);
                QQHPSwizzle(c, @selector(shouldShowAvatarPendant),
                            (IMP)&hook_shouldShowPendant, (IMP *)&orig_shouldShowPendant);
            }
        }

        // 4. 字体
        {
            Class c = NSClassFromString(@"QQAIOFontManager");
            if (c != Nil) {
                QQHPSwizzle(c, @selector(aioTextFont), (IMP)&hook_aioTextFont, (IMP *)&orig_aioTextFont);
                QQHPSwizzle(c, @selector(aioNickFont), (IMP)&hook_aioNickFont, (IMP *)&orig_aioNickFont);
                QQHPSwizzle(c, @selector(aioTimeFont), (IMP)&hook_aioTimeFont, (IMP *)&orig_aioTimeFont);
                QQHPSwizzle(c, @selector(aioVideoFont), (IMP)&hook_aioVideoFont, (IMP *)&orig_aioVideoFont);
            }
        }

        // 5. 天气
        {
            Class c = NSClassFromString(@"QQWeatherView");
            if (c != Nil)
                QQHPSwizzle(c, @selector(init), (IMP)&hook_weatherInit, (IMP *)&orig_weatherInit);
        }

        // 6. 礼物动画
        {
            Class c = NSClassFromString(@"QQGroupDeliverGiftAnimationManager");
            if (c != Nil)
                QQHPSwizzle(c, @selector(startAnimation), (IMP)&hook_startAnimation,
                            (IMP *)&orig_startAnimation);
        }

        // 7. 表情联想
        {
            Class c = NSClassFromString(@"QQFaceAssociateFrameView");
            if (c != Nil)
                QQHPSwizzle(c, @selector(loadFace:hasCloudEmoji:keywords:),
                            (IMP)&hook_loadFace, (IMP *)&orig_loadFace);
        }

        // 8. 推荐表情
        {
            Class c = NSClassFromString(@"QQFacePanelController");
            if (c != Nil)
                QQHPSwizzle(c, @selector(loadEmojiStoreFace),
                            (IMP)&hook_loadEmojiStoreFace, (IMP *)&orig_loadEmojiStoreFace);
        }

        // 9. QQ空间去广告
        {
            Class c = NSClassFromString(@"MQZoneAdBannerView");
            if (c != Nil)
                QQHPSwizzle(c, @selector(initWithFrame:adBannerUnit:),
                            (IMP)&hook_adBannerInit, (IMP *)&orig_adBannerInit);

            c = NSClassFromString(@"QZoneBannerAdView");
            if (c != Nil) {
                QQHPSwizzle(c, @selector(initWithFrame:),
                            (IMP)&hook_bannerInit, (IMP *)&orig_bannerInit);
                QQHPSwizzle(c, @selector(updateBanner),
                            (IMP)&hook_updateBanner, (IMP *)&orig_updateBanner);
            }

            c = NSClassFromString(@"MQZoneDetailAdBannerCell");
            if (c != Nil)
                QQHPSwizzle(c, @selector(heightForCell),
                            (IMP)&hook_detailAdHeight, (IMP *)&orig_detailAdHeight);
        }

        QQHPLog(@"init done");
    }
}
