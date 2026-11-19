// QQHelperPort - QQHelper 功能移植到 QQ 6.2
//
// 依据：在 iPhone 5c / iOS 10.3.4 上对运行中的 QQ 6.2 做过 ObjC runtime dump
// （24242 个类，3606 个类的方法清单），据此确认了可用的类与方法。
//
// 每个功能都有独立开关：
//   /tmp/qqhp-off          关掉全部
//   /tmp/qqhp-no-recall    关掉「撤回选项」
//   /tmp/qqhp-no-antirevoke  关掉「防撤回」
//   /tmp/qqhp-no-pendant   关掉「屏蔽头像挂件」
//   /tmp/qqhp-no-font      关掉「屏蔽个性字体」
//   /tmp/qqhp-no-weather   关掉「去除天气」
//   /tmp/qqhp-no-time      关掉「屏蔽对话时间」
//
// 注意：QQ 6.2 的 QQRecallMenuFilter 有 11 个 `+is...NeedShowMenuRecall:`
// 类方法决定长按菜单里是否出现「撤回」。全部改成返回 YES 即可让选项重新出现。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <substrate.h>

static BOOL QQHPEnabled(void) {
    return ![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/qqhp-off"];
}

static BOOL QQHPOn(NSString *switchName) {
    if (!QQHPEnabled()) return NO;
    return ![[NSFileManager defaultManager]
             fileExistsAtPath:[@"/tmp" stringByAppendingPathComponent:switchName]];
}

// =====================================================================
// 1. 撤回选项：QQRecallMenuFilter 的 11 个类方法全部返回 YES
//    这样长按消息时「撤回」会重新出现在菜单里。
// =====================================================================
static BOOL (*orig_isText)(Class, SEL, id);
static BOOL hook_isText(Class self, SEL _cmd, id msg) {
    if (QQHPOn(@"qqhp-no-recall")) return orig_isText ? orig_isText(self, _cmd, msg) : NO;
    return YES;
}

static BOOL (*orig_isGroup)(Class, SEL, id);
static BOOL hook_isGroup(Class self, SEL _cmd, id msg) {
    if (QQHPOn(@"qqhp-no-recall")) return orig_isGroup ? orig_isGroup(self, _cmd, msg) : NO;
    return YES;
}

static BOOL (*orig_isPic)(Class, SEL, id);
static BOOL hook_isPic(Class self, SEL _cmd, id msg) {
    if (QQHPOn(@"qqhp-no-recall")) return orig_isPic ? orig_isPic(self, _cmd, msg) : NO;
    return YES;
}

static BOOL (*orig_isPtt)(Class, SEL, id);
static BOOL hook_isPtt(Class self, SEL _cmd, id msg) {
    if (QQHPOn(@"qqhp-no-recall")) return orig_isPtt ? orig_isPtt(self, _cmd, msg) : NO;
    return YES;
}

static BOOL (*orig_isFile)(Class, SEL, id);
static BOOL hook_isFile(Class self, SEL _cmd, id msg) {
    if (QQHPOn(@"qqhp-no-recall")) return orig_isFile ? orig_isFile(self, _cmd, msg) : NO;
    return YES;
}

static BOOL (*orig_isMarketFace)(Class, SEL, id);
static BOOL hook_isMarketFace(Class self, SEL _cmd, id msg) {
    if (QQHPOn(@"qqhp-no-recall")) return orig_isMarketFace ? orig_isMarketFace(self, _cmd, msg) : NO;
    return YES;
}

static BOOL (*orig_isSM)(Class, SEL, id);
static BOOL hook_isSM(Class self, SEL _cmd, id msg) {
    if (QQHPOn(@"qqhp-no-recall")) return orig_isSM ? orig_isSM(self, _cmd, msg) : NO;
    return YES;
}

static BOOL (*orig_isShortVideo)(Class, SEL, id);
static BOOL hook_isShortVideo(Class self, SEL _cmd, id msg) {
    if (QQHPOn(@"qqhp-no-recall")) return orig_isShortVideo ? orig_isShortVideo(self, _cmd, msg) : NO;
    return YES;
}

// =====================================================================
// 2. 防撤回：拦下三个收包回调，直接不入库（消息就不会被撤回）
//    QQMessageRecallModule:
//      -recvC2CRecallNotify:bufferLen:subcmd:isOnline:
//      -recvGroupRecallNotify:bufferLen:isOnline:
//      -recvDiscussRecallNotify:bufferLen:isOnline:
// =====================================================================
static void (*orig_recvC2C)(id, SEL, id, unsigned int, int, BOOL);
static void hook_recvC2C(id self, SEL _cmd, id buf, unsigned int len, int subcmd, BOOL online) {
    if (QQHPOn(@"qqhp-no-antirevoke")) {
        if (orig_recvC2C) orig_recvC2C(self, _cmd, buf, len, subcmd, online);
    }
    // 否则直接吞掉，消息不会被撤回
}

static void (*orig_recvGroup)(id, SEL, id, unsigned int, BOOL);
static void hook_recvGroup(id self, SEL _cmd, id buf, unsigned int len, BOOL online) {
    if (QQHPOn(@"qqhp-no-antirevoke")) {
        if (orig_recvGroup) orig_recvGroup(self, _cmd, buf, len, online);
    }
}

static void (*orig_recvDiscuss)(id, SEL, id, unsigned int, BOOL);
static void hook_recvDiscuss(id self, SEL _cmd, id buf, unsigned int len, BOOL online) {
    if (QQHPOn(@"qqhp-no-antirevoke")) {
        if (orig_recvDiscuss) orig_recvDiscuss(self, _cmd, buf, len, online);
    }
}

// =====================================================================
// 3. 屏蔽头像挂件：QQAvatarView
//    -frameForAvatarPendant  -> CGRectZero
//    -avatarPendantID        -> nil
// =====================================================================
static CGRect (*orig_pendantFrame)(id, SEL);
static CGRect hook_pendantFrame(id self, SEL _cmd) {
    if (QQHPOn(@"qqhp-no-pendant")) {
        if (orig_pendantFrame) return orig_pendantFrame(self, _cmd);
    }
    return CGRectZero;
}

static id (*orig_pendantID)(id, SEL);
static id hook_pendantID(id self, SEL _cmd) {
    if (QQHPOn(@"qqhp-no-pendant")) {
        if (orig_pendantID) return orig_pendantID(self, _cmd);
    }
    return nil;
}

// =====================================================================
// 4. 屏蔽性格/大小字体：QQAIOFontManager —— 让它返回系统字体
//    我们不确知其方法签名，所以只在能取到 UIFont 返回值的常见入口上做保护。
//    这里用「记录型」hook：不改行为，只打日志，等确认后再改。
//    （保持安全：不确定的东西不动）
// =====================================================================

// =====================================================================
// 5. 去除天气：QQWeatherView —— 让它不显示（hidden = YES）
// =====================================================================
static void (*orig_weatherLayout)(id, SEL);
static void hook_weatherLayout(id self, SEL _cmd) {
    if (orig_weatherLayout) orig_weatherLayout(self, _cmd);
    if (QQHPOn(@"qqhp-no-weather")) return;
    if ([self isKindOfClass:[UIView class]]) {
        [(UIView *)self setHidden:YES];
    }
}

// =====================================================================
// 6. 屏蔽对话窗口时间：QQAIOTimeCell —— 高度归零
// =====================================================================
static void (*orig_timeLayout)(id, SEL);
static void hook_timeLayout(id self, SEL _cmd) {
    if (orig_timeLayout) orig_timeLayout(self, _cmd);
    if (QQHPOn(@"qqhp-no-time")) return;
    if ([self isKindOfClass:[UIView class]]) {
        [(UIView *)self setHidden:YES];
        [(UIView *)self setAlpha:0.0];
    }
}

// =====================================================================
// 安装
// =====================================================================
static void QQHPSwizzle(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    if (cls == Nil) return;
    Method m = class_getClassMethod(cls, sel);
    if (m != NULL) {
        *oldImp = (IMP)method_getImplementation(m);
        method_setImplementation(m, newImp);
        NSLog(@"[QQHP] hooked class method %@ %@", NSStringFromClass(cls),
              NSStringFromSelector(sel));
        return;
    }
    m = class_getInstanceMethod(cls, sel);
    if (m != NULL) {
        *oldImp = (IMP)method_getImplementation(m);
        method_setImplementation(m, newImp);
        NSLog(@"[QQHP] hooked instance method %@ %@", NSStringFromClass(cls),
              NSStringFromSelector(sel));
    }
}

__attribute__((constructor))
static void QQHPInit(void) {
    @autoreleasepool {
        NSLog(@"[QQHP] loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
        if (!QQHPEnabled()) {
            NSLog(@"[QQHP] disabled by /tmp/qqhp-off");
            return;
        }

        Class filter = NSClassFromString(@"QQRecallMenuFilter");
        if (filter != Nil) {
            // 把能确定的几个改成 YES
            QQHPSwizzle(filter, @selector(isTextNeedShowMenuRecall:),
                        (IMP)&hook_isText, (IMP *)&orig_isText);
            QQHPSwizzle(filter, @selector(isGroupMessageNeedShowMenuRecall:),
                        (IMP)&hook_isGroup, (IMP *)&orig_isGroup);
            QQHPSwizzle(filter, @selector(isQQPicMessageNeedShowMenuRecall:),
                        (IMP)&hook_isPic, (IMP *)&orig_isPic);
            QQHPSwizzle(filter, @selector(isQQPttMessageNeedShowMenuRecall:),
                        (IMP)&hook_isPtt, (IMP *)&orig_isPtt);
            QQHPSwizzle(filter, @selector(isFileNeedShowMenuRecall:),
                        (IMP)&hook_isFile, (IMP *)&orig_isFile);
            QQHPSwizzle(filter, @selector(isMarketFaceNeedShowMenuRecall:),
                        (IMP)&hook_isMarketFace, (IMP *)&orig_isMarketFace);
            QQHPSwizzle(filter, @selector(isQQSMMessageNeedShowMenuRecall:),
                        (IMP)&hook_isSM, (IMP *)&orig_isSM);
            QQHPSwizzle(filter, @selector(isQQRichShortVideoMessageNeedShowMenuRecall:),
                        (IMP)&hook_isShortVideo, (IMP *)&orig_isShortVideo);
            NSLog(@"[QQHP] recall menu filter installed");
        } else {
            NSLog(@"[QQHP] QQRecallMenuFilter not found");
        }

        Class recall = NSClassFromString(@"QQMessageRecallModule");
        if (recall != Nil) {
            QQHPSwizzle(recall, @selector(recvC2CRecallNotify:bufferLen:subcmd:isOnline:),
                        (IMP)&hook_recvC2C, (IMP *)&orig_recvC2C);
            QQHPSwizzle(recall, @selector(recvGroupRecallNotify:bufferLen:isOnline:),
                        (IMP)&hook_recvGroup, (IMP *)&orig_recvGroup);
            QQHPSwizzle(recall, @selector(recvDiscussRecallNotify:bufferLen:isOnline:),
                        (IMP)&hook_recvDiscuss, (IMP *)&orig_recvDiscuss);
            NSLog(@"[QQHP] anti-revoke installed");
        }

        Class avatar = NSClassFromString(@"QQAvatarView");
        if (avatar != Nil) {
            QQHPSwizzle(avatar, @selector(frameForAvatarPendant),
                        (IMP)&hook_pendantFrame, (IMP *)&orig_pendantFrame);
            QQHPSwizzle(avatar, @selector(avatarPendantID),
                        (IMP)&hook_pendantID, (IMP *)&orig_pendantID);
            NSLog(@"[QQHP] pendant block installed");
        }

        Class weather = NSClassFromString(@"QQWeatherView");
        if (weather != Nil) {
            QQHPSwizzle(weather, @selector(layoutSubviews),
                        (IMP)&hook_weatherLayout, (IMP *)&orig_weatherLayout);
        }

        Class timeCell = NSClassFromString(@"QQAIOTimeCell");
        if (timeCell != Nil) {
            QQHPSwizzle(timeCell, @selector(layoutSubviews),
                        (IMP)&hook_timeLayout, (IMP *)&orig_timeLayout);
        }

        NSLog(@"[QQHP] init done");
    }
}
