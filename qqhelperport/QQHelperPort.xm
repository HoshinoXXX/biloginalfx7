// QQHelperPort - QQHelper features ported to QQ 6.2
//
// Based on an ObjC runtime dump taken from the running QQ 6.2 process on an
// iPhone 5c / iOS 10.3.4 (24,242 classes, method lists for 3,606 classes).
//
// LESSON LEARNED (this crashed QQ once on 2026-11-19):
//   On armv7 a 16-byte struct like CGRect is NOT returned in registers - the
//   caller passes a hidden sret pointer as the first argument. Declaring
//   `-frameForAvatarPendant` as `CGRect (id, SEL)` is therefore wrong and
//   smashes the caller's stack; the symptom was EXC_BAD_ACCESS at 0x1e0.
//   This build does not hook any struct-returning method, and logs
//   method_getTypeEncoding for everything it does hook so signatures can be
//   verified afterwards.
//
// Kill switches:
//   /tmp/qqhp-off            disable everything
//   /tmp/qqhp-no-recall      disable the recall menu fix
//   /tmp/qqhp-no-antirevoke  disable anti-revoke
//   /tmp/qqhp-no-weather     disable weather removal
//   /tmp/qqhp-no-time        disable chat timestamp hiding

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// iOS 10 logs through ASL and has no /var/log/syslog, so mirror into a file.
static void QQHPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[QQHP] %@", s);
    NSString *path = @"/tmp/qqhp.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[[NSString stringWithFormat:@"[QQHP] %@\n", s]
                       dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static BOOL QQHPEnabled(void) {
    return ![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/qqhp-off"];
}

static BOOL QQHPOn(NSString *switchName) {
    if (!QQHPEnabled()) return NO;
    return ![[NSFileManager defaultManager]
             fileExistsAtPath:[@"/tmp" stringByAppendingPathComponent:switchName]];
}

// =====================================================================
// 1. Recall menu: QQRecallMenuFilter's eight BOOL class methods -> always YES
//    Signature is (Class, SEL, id) -> BOOL, matching the originals.
// =====================================================================
#define QQHP_BOOL_HOOK(NAME)                                                  \
    static BOOL (*orig_##NAME)(Class, SEL, id);                               \
    static BOOL hook_##NAME(Class self, SEL _cmd, id arg) {                   \
        if (!QQHPOn(@"qqhp-no-recall")) return YES;                           \
        return orig_##NAME ? orig_##NAME(self, _cmd, arg) : NO;               \
    }

QQHP_BOOL_HOOK(isText)
QQHP_BOOL_HOOK(isGroup)
QQHP_BOOL_HOOK(isPic)
QQHP_BOOL_HOOK(isPtt)
QQHP_BOOL_HOOK(isFile)
QQHP_BOOL_HOOK(isMarketFace)
QQHP_BOOL_HOOK(isSM)
QQHP_BOOL_HOOK(isShortVideo)

// =====================================================================
// 2. Anti-revoke: swallow the three recall callbacks (both return void)
// =====================================================================
static void (*orig_recvC2C)(id, SEL, id, unsigned int, int, BOOL);
static void hook_recvC2C(id self, SEL _cmd, id buf, unsigned int len,
                         int subcmd, BOOL online) {
    if (QQHPOn(@"qqhp-no-antirevoke")) {
        if (orig_recvC2C) orig_recvC2C(self, _cmd, buf, len, subcmd, online);
    }
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
// 3. Weather removal / timestamp hiding: hook void layoutSubviews, then hide
// =====================================================================
static void (*orig_weatherLayout)(id, SEL);
static void hook_weatherLayout(id self, SEL _cmd) {
    if (orig_weatherLayout) orig_weatherLayout(self, _cmd);
    if (!QQHPOn(@"qqhp-no-weather")) {
        if ([self isKindOfClass:[UIView class]]) [(UIView *)self setHidden:YES];
    }
}

static void (*orig_timeLayout)(id, SEL);
static void hook_timeLayout(id self, SEL _cmd) {
    if (orig_timeLayout) orig_timeLayout(self, _cmd);
    if (!QQHPOn(@"qqhp-no-time")) {
        if ([self isKindOfClass:[UIView class]]) {
            [(UIView *)self setHidden:YES];
            [(UIView *)self setAlpha:0.0];
        }
    }
}

// =====================================================================
// Install helper: logs the type encoding so signatures can be verified
// =====================================================================
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
    const char *enc = method_getTypeEncoding(m);
    QQHPLog(@"hook %-8s %@ %@  encoding=%s", scope, NSStringFromClass(cls),
            NSStringFromSelector(sel), enc ? enc : "?");
    *oldImp = (IMP)method_getImplementation(m);
    method_setImplementation(m, newImp);
}

__attribute__((constructor))
static void QQHPInit(void) {
    @autoreleasepool {
        QQHPLog(@"loaded into %@ (home=%@)", [[NSBundle mainBundle] bundleIdentifier],
                NSHomeDirectory());
        if (!QQHPEnabled()) {
            QQHPLog(@"disabled by /tmp/qqhp-off");
            return;
        }

        Class filter = NSClassFromString(@"QQRecallMenuFilter");
        if (filter != Nil) {
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
        } else {
            QQHPLog(@"QQRecallMenuFilter not found");
        }

        Class recall = NSClassFromString(@"QQMessageRecallModule");
        if (recall != Nil) {
            QQHPSwizzle(recall, @selector(recvC2CRecallNotify:bufferLen:subcmd:isOnline:),
                        (IMP)&hook_recvC2C, (IMP *)&orig_recvC2C);
            QQHPSwizzle(recall, @selector(recvGroupRecallNotify:bufferLen:isOnline:),
                        (IMP)&hook_recvGroup, (IMP *)&orig_recvGroup);
            QQHPSwizzle(recall, @selector(recvDiscussRecallNotify:bufferLen:isOnline:),
                        (IMP)&hook_recvDiscuss, (IMP *)&orig_recvDiscuss);
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

        QQHPLog(@"init done");
    }
}
