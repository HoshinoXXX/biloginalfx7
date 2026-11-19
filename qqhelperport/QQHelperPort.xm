// QQHelperPort - QQHelper features ported to QQ 6.2
//
// Based on an ObjC runtime dump from the running QQ 6.2 (iPhone 5c / iOS 10.3.4,
// 24,242 classes, method lists for 3,606 classes).
//
// ============================ HARD-WON RULES ============================
// 1. NEVER hook a struct-returning method directly. On armv7 a 16-byte struct
//    (CGRect) comes back through a hidden sret pointer; declaring it as
//    `CGRect (id, SEL)` smashed the caller's stack and crashed QQ with
//    EXC_BAD_ACCESS at 0x1e0. Use object-returning or void methods instead
//    (`avatarPendantID` -> nil is the safe way to kill pendants).
// 2. NEVER hide a UITableView cell to "remove" it. Hiding QQAIOTimeCell (the
//    chat section header) collapsed the whole message table, so no messages
//    rendered at all. The timestamp feature is therefore dropped.
// 3. Kill switches must EARLY-RETURN when disabled, not gate the action with
//    a negated helper - the first build had that inverted, so the switches did
//    nothing.
// ========================================================================
//
// Kill switches (create the file to disable that feature):
//   /tmp/qqhp-off             everything
//   /tmp/qqhp-no-recall       recall menu fix
//   /tmp/qqhp-no-antirevoke   anti-revoke
//   /tmp/qqhp-no-pendant      avatar pendant hiding
//   /tmp/qqhp-no-font         custom font blocking
//   /tmp/qqhp-no-weather      weather removal
//   /tmp/qqhp-no-gift         gift animation blocking
//   /tmp/qqhp-no-faceassoc    emoji suggestion blocking
//   /tmp/qqhp-no-facestore    recommended emoji blocking

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// ------------------------------------------------------------------ logging
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

// ------------------------------------------------------------- kill switches
// Returns YES when the named feature is DISABLED.
static BOOL QQHPOff(NSString *switchName) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/qqhp-off"]) return YES;
    return [[NSFileManager defaultManager]
            fileExistsAtPath:[@"/tmp" stringByAppendingPathComponent:switchName]];
}

// ===================== 1. Recall menu (QQRecallMenuFilter) =================
// Eight class methods, encoding c12@0:4@8 = BOOL (Class, SEL, id).
#define QQHP_BOOL_HOOK(NAME)                                                  \
    static BOOL (*orig_##NAME)(Class, SEL, id);                               \
    static BOOL hook_##NAME(Class self, SEL _cmd, id arg) {                   \
        if (QQHPOff(@"qqhp-no-recall"))                                       \
            return orig_##NAME ? orig_##NAME(self, _cmd, arg) : NO;           \
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

// ==================== 2. Anti-revoke (QQMessageRecallModule) ==============
//  -recvC2CRecallNotify:bufferLen:subcmd:isOnline:  v24@0:4r^v8i12i16c20
//  -recvGroupRecallNotify:bufferLen:isOnline:       v20@0:4*8I12c16
//  -recvDiscussRecallNotify:bufferLen:isOnline:     v20@0:4*8I12c16
static void (*orig_recvC2C)(id, SEL, void *, int, int, char);
static void hook_recvC2C(id self, SEL _cmd, void *buf, int len, int subcmd, char online) {
    if (QQHPOff(@"qqhp-no-antirevoke")) {
        if (orig_recvC2C) orig_recvC2C(self, _cmd, buf, len, subcmd, online);
    }
}

static void (*orig_recvGroup)(id, SEL, void *, unsigned int, char);
static void hook_recvGroup(id self, SEL _cmd, void *buf, unsigned int len, char online) {
    if (QQHPOff(@"qqhp-no-antirevoke")) {
        if (orig_recvGroup) orig_recvGroup(self, _cmd, buf, len, online);
    }
}

static void (*orig_recvDiscuss)(id, SEL, void *, unsigned int, char);
static void hook_recvDiscuss(id self, SEL _cmd, void *buf, unsigned int len, char online) {
    if (QQHPOff(@"qqhp-no-antirevoke")) {
        if (orig_recvDiscuss) orig_recvDiscuss(self, _cmd, buf, len, online);
    }
}

// ================== 3. Avatar pendant (QQAvatarView) =====================
// Object-returning and void methods only - never the CGRect one.
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

// ================== 4. Custom font (QQAIOFontManager) ====================
// All four return UIFont (object) - replace with the system font.
static UIFont *QQHPSystemFont(CGFloat size) {
    return [UIFont systemFontOfSize:(size > 0 ? size : 16.0)];
}

static UIFont *(*orig_aioTextFont)(id, SEL);
static UIFont *hook_aioTextFont(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-font")) return orig_aioTextFont ? orig_aioTextFont(self, _cmd) : nil;
    return QQHPSystemFont(16.0);
}

static UIFont *(*orig_aioNickFont)(id, SEL);
static UIFont *hook_aioNickFont(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-font")) return orig_aioNickFont ? orig_aioNickFont(self, _cmd) : nil;
    return QQHPSystemFont(13.0);
}

static UIFont *(*orig_aioTimeFont)(id, SEL);
static UIFont *hook_aioTimeFont(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-font")) return orig_aioTimeFont ? orig_aioTimeFont(self, _cmd) : nil;
    return QQHPSystemFont(11.0);
}

static UIFont *(*orig_aioVideoFont)(id, SEL);
static UIFont *hook_aioVideoFont(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-font")) return orig_aioVideoFont ? orig_aioVideoFont(self, _cmd) : nil;
    return QQHPSystemFont(13.0);
}

// ====================== 5. Weather (QQWeatherView) =======================
// Hook -init (object return) and hide the view afterwards. Does not touch
// layoutSubviews, so nothing collapses.
static id (*orig_weatherInit)(id, SEL);
static id hook_weatherInit(id self, SEL _cmd) {
    id r = orig_weatherInit ? orig_weatherInit(self, _cmd) : nil;
    if (!QQHPOff(@"qqhp-no-weather") && [r isKindOfClass:[UIView class]])
        [(UIView *)r setHidden:YES];
    return r;
}

// ============ 6. Gift animation (QQGroupDeliverGiftAnimationManager) =====
static void (*orig_startAnimation)(id, SEL);
static void hook_startAnimation(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-gift")) {
        if (orig_startAnimation) orig_startAnimation(self, _cmd);
    }
}

// ============ 7. Emoji suggestion (QQFaceAssociateFrameView) ============
static void (*orig_loadFace)(id, SEL, id, BOOL, id);
static void hook_loadFace(id self, SEL _cmd, id face, BOOL cloud, id keywords) {
    if (QQHPOff(@"qqhp-no-faceassoc")) {
        if (orig_loadFace) orig_loadFace(self, _cmd, face, cloud, keywords);
    }
}

// ============ 8. Recommended emoji (QQFacePanelController) ==============
static void (*orig_loadEmojiStoreFace)(id, SEL);
static void hook_loadEmojiStoreFace(id self, SEL _cmd) {
    if (QQHPOff(@"qqhp-no-facestore")) {
        if (orig_loadEmojiStoreFace) orig_loadEmojiStoreFace(self, _cmd);
    }
}

// ============================ install helper ============================
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

#define QQHP_HOOK(CLSNAME, SELNAME, HOOKFN, ORIGVAR)                          \
    do {                                                                      \
        Class c = NSClassFromString(@#CLSNAME);                               \
        if (c != Nil)                                                         \
            QQHPSwizzle(c, @selector(SELNAME), (IMP)&HOOKFN, (IMP *)&ORIGVAR); \
        else                                                                  \
            QQHPLog(@"class missing: %@", @#CLSNAME);                         \
    } while (0)

__attribute__((constructor))
static void QQHPInit(void) {
    @autoreleasepool {
        QQHPLog(@"loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/qqhp-off"]) {
            QQHPLog(@"globally disabled by /tmp/qqhp-off");
            return;
        }

        // 1. recall menu
        {
            Class c = NSClassFromString(@"QQRecallMenuFilter");
            if (c != Nil) {
                QQHPSwizzle(c, @selector(isTextNeedShowMenuRecall:), (IMP)&hook_isText, (IMP *)&orig_isText);
                QQHPSwizzle(c, @selector(isGroupMessageNeedShowMenuRecall:), (IMP)&hook_isGroup, (IMP *)&orig_isGroup);
                QQHPSwizzle(c, @selector(isQQPicMessageNeedShowMenuRecall:), (IMP)&hook_isPic, (IMP *)&orig_isPic);
                QQHPSwizzle(c, @selector(isQQPttMessageNeedShowMenuRecall:), (IMP)&hook_isPtt, (IMP *)&orig_isPtt);
                QQHPSwizzle(c, @selector(isFileNeedShowMenuRecall:), (IMP)&hook_isFile, (IMP *)&orig_isFile);
                QQHPSwizzle(c, @selector(isMarketFaceNeedShowMenuRecall:), (IMP)&hook_isMarketFace, (IMP *)&orig_isMarketFace);
                QQHPSwizzle(c, @selector(isQQSMMessageNeedShowMenuRecall:), (IMP)&hook_isSM, (IMP *)&orig_isSM);
                QQHPSwizzle(c, @selector(isQQRichShortVideoMessageNeedShowMenuRecall:), (IMP)&hook_isShortVideo, (IMP *)&orig_isShortVideo);
            } else {
                QQHPLog(@"QQRecallMenuFilter missing");
            }
        }

        // 2. anti-revoke
        QQHP_HOOK(QQMessageRecallModule, recvC2CRecallNotify:bufferLen:subcmd:isOnline:, hook_recvC2C, orig_recvC2C);
        QQHP_HOOK(QQMessageRecallModule, recvGroupRecallNotify:bufferLen:isOnline:, hook_recvGroup, orig_recvGroup);
        QQHP_HOOK(QQMessageRecallModule, recvDiscussRecallNotify:bufferLen:isOnline:, hook_recvDiscuss, orig_recvDiscuss);

        // 3. avatar pendant
        QQHP_HOOK(QQAvatarView, setShouldShowAvatarPendant:, hook_setShouldShowPendant, orig_setShouldShowPendant);
        QQHP_HOOK(QQAvatarView, avatarPendantID, hook_pendantID, orig_pendantID);
        QQHP_HOOK(QQAvatarView, shouldShowAvatarPendant, hook_shouldShowPendant, orig_shouldShowPendant);

        // 4. custom font
        QQHP_HOOK(QQAIOFontManager, aioTextFont, hook_aioTextFont, orig_aioTextFont);
        QQHP_HOOK(QQAIOFontManager, aioNickFont, hook_aioNickFont, orig_aioNickFont);
        QQHP_HOOK(QQAIOFontManager, aioTimeFont, hook_aioTimeFont, orig_aioTimeFont);
        QQHP_HOOK(QQAIOFontManager, aioVideoFont, hook_aioVideoFont, orig_aioVideoFont);

        // 5. weather
        QQHP_HOOK(QQWeatherView, init, hook_weatherInit, orig_weatherInit);

        // 6. gift animation
        QQHP_HOOK(QQGroupDeliverGiftAnimationManager, startAnimation, hook_startAnimation, orig_startAnimation);

        // 7. emoji suggestion
        QQHP_HOOK(QQFaceAssociateFrameView, loadFace:hasCloudEmoji:keywords:, hook_loadFace, orig_loadFace);

        // 8. recommended emoji
        QQHP_HOOK(QQFacePanelController, loadEmojiStoreFace, hook_loadEmojiStoreFace, orig_loadEmojiStoreFace);

        QQHPLog(@"init done");
    }
}
