// QQHelperPort - QQHelper ?蝘餅???QQ 6.2
//
// 靘嚗 iPhone 5c / iOS 10.3.4 銝笆餈?銝剔? QQ 6.2 ?? ObjC runtime dump
// 嚗?4242 銝芰掩嚗?606 銝芰掩?瘜???嚗甇斤＆霈支??舐?掩銝瘜?//
// 瘥葵??賣??祉?撘?喉?
//   /tmp/qqhp-off          ?單??券
//   /tmp/qqhp-no-recall    ?單???★??//   /tmp/qqhp-no-antirevoke  ?單???文???//   /tmp/qqhp-no-pendant   ?單????賢仍??隞嗚?//   /tmp/qqhp-no-font      ?單????賭葵?批?雿?//   /tmp/qqhp-no-weather   ?單???文予瘞?//   /tmp/qqhp-no-time      ?單????賢笆霂?氬?//
// 瘜冽?嚗Q 6.2 ??QQRecallMenuFilter ??11 銝?`+is...NeedShowMenuRecall:`
// 蝐餅瘜摰?????臬?箇???冽????YES ?喳霈拚★??箇??
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <substrate.h>

// iOS 10 logs through ASL and has no /var/log/syslog, so mirror every message
// into a plain file that can be read over SSH.
static void QQHPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[QQHP] %@", s);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/qqhp.log"];
    if (fh == nil) {
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/qqhp.log"
                                                contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/qqhp.log"];
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
// 1. ?文??★嚗QRecallMenuFilter ??11 銝芰掩?寞??券餈? YES
//    餈?踵?瘨?嗚????箇?刻?????// =====================================================================
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
// 2. ?脫???虫?銝葵?嗅???嚗?乩??亙?嚗??臬停銝?鋡急??
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
    // ?血??湔??嚗??臭?隡◤?文?
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
// 3. 撅憭游??辣嚗QAvatarView
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
// 4. 撅?扳/憭批?摮?嚗QAIOFontManager ??霈拙?餈?蝟餌?摮?
//    ?賑銝＆?亙?寞?蝑曉?嚗?隞亙?刻? UIFont 餈??潛?撣貉??亙銝?靽??//    餈??具扇敶??ook嚗??寡?銝綽??芣??亙?嚗?蝖株恕???嫘?//    嚗????剁?銝＆摰?銝正銝嚗?// =====================================================================

// =====================================================================
// 5. ?駁憭拇?嚗QWeatherView ??霈拙?銝蝷綽?hidden = YES嚗?// =====================================================================
static void (*orig_weatherLayout)(id, SEL);
static void hook_weatherLayout(id self, SEL _cmd) {
    if (orig_weatherLayout) orig_weatherLayout(self, _cmd);
    if (QQHPOn(@"qqhp-no-weather")) return;
    if ([self isKindOfClass:[UIView class]]) {
        [(UIView *)self setHidden:YES];
    }
}

// =====================================================================
// 6. 撅撖寡?蝒?園嚗QAIOTimeCell ??擃漲敶
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
// 摰?
// =====================================================================
static void QQHPSwizzle(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    if (cls == Nil) return;
    Method m = class_getClassMethod(cls, sel);
    if (m != NULL) {
        *oldImp = (IMP)method_getImplementation(m);
        method_setImplementation(m, newImp);
        QQHPLog(@"hooked class method %@ %@", NSStringFromClass(cls),
              NSStringFromSelector(sel));
        return;
    }
    m = class_getInstanceMethod(cls, sel);
    if (m != NULL) {
        *oldImp = (IMP)method_getImplementation(m);
        method_setImplementation(m, newImp);
        QQHPLog(@"hooked instance method %@ %@", NSStringFromClass(cls),
              NSStringFromSelector(sel));
    }
}

__attribute__((constructor))
static void QQHPInit(void) {
    @autoreleasepool {
        QQHPLog(@"loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
        if (!QQHPEnabled()) {
            QQHPLog(@"disabled by /tmp/qqhp-off");
            return;
        }

        Class filter = NSClassFromString(@"QQRecallMenuFilter");
        if (filter != Nil) {
            // ?蝖桀???銝芣??YES
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
            QQHPLog(@"recall menu filter installed");
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
            QQHPLog(@"anti-revoke installed");
        }

        Class avatar = NSClassFromString(@"QQAvatarView");
        if (avatar != Nil) {
            QQHPSwizzle(avatar, @selector(frameForAvatarPendant),
                        (IMP)&hook_pendantFrame, (IMP *)&orig_pendantFrame);
            QQHPSwizzle(avatar, @selector(avatarPendantID),
                        (IMP)&hook_pendantID, (IMP *)&orig_pendantID);
            QQHPLog(@"pendant block installed");
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
