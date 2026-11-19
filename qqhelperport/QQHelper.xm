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

// 前向声明（实现在下面的诊断段里）
static void QQHNoteCell(id cell);

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

// ---------------- 广告 cell 诊断：打印动态列表里的真实类名 ----------------
static int QQHCellLogCount = 0;
static void QQHNoteCell(id cell) {
    if (QQHCellLogCount >= 40) return;
    QQHCellLogCount++;
    QQHPLog(@"[cell] %@", NSStringFromClass([cell class]));
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
        }

        QQHPLog(@"init done");
    }
}
