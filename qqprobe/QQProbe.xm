// QQProbe - read-only probe
//
// Dumps the ObjC runtime of the QQ process so a "QQHelper feature -> QQ 6.2
// class name" mapping can be built.
//
// Safety:
//   * only calls objc_getClassList / class_copyMethodList (read only)
//   * writes only text dumps, into the app's own Documents directory and /tmp
//   * never touches QQ's data, preferences or network
//   * hooks nothing, changes no behaviour
//
// Note: iOS apps are sandboxed, so /tmp is usually NOT writable from inside the
// app. NSHomeDirectory() points at the app's data container, which always is.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSArray *QQProbeKeys(void) {
    static NSArray *k = nil;
    if (k == nil) {
        k = @[@"Recall", @"Revoke", @"Message", @"Msg", @"Bubble", @"Font",
              @"Pendant", @"Avatar", @"Weather", @"Splash", @"Gift", @"Face",
              @"Emoji", @"Time", @"Level", @"Pay", @"Menu", @"AIO", @"Ad",
              @"Setting", @"Panel", @"Cell", @"Label",
              // second sweep: online status, card likes (365), red packets, group admin
              @"Online", @"Presence", @"Status", @"Net", @"Wifi", @"WiFi",
              @"Zan", @"Praise", @"CardInfo", @"Like",
              @"RedPack", @"RedEnvelope", @"Hongbao", @"Lucky",
              @"Admin", @"GroupMember", @"Owner", @"Member",
              @"Drawer", @"Dynamic", @"TabBar", @"Device", @"Model",
              @"Banner", @"Promo", @"QZone", @"Qzone", @"Feed"];
    }
    return k;
}

static NSArray *QQProbeWritableDirs(void) {
    NSMutableArray *dirs = [NSMutableArray array];
    NSString *home = NSHomeDirectory();
    if (home) {
        [dirs addObject:[home stringByAppendingPathComponent:@"Documents"]];
        [dirs addObject:home];
        [dirs addObject:[home stringByAppendingPathComponent:@"Library"]];
    }
    [dirs addObject:@"/tmp"];
    [dirs addObject:@"/var/mobile"];
    return dirs;
}

static void QQProbeWrite(NSString *name, NSString *text) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger wrote = 0;
    for (NSString *dir in QQProbeWritableDirs()) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                        attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL ok = [text writeToFile:path atomically:YES
                           encoding:NSUTF8StringEncoding error:NULL];
        if (ok) {
            wrote++;
            NSLog(@"[QQProbe] wrote %@", path);
        }
    }
    NSLog(@"[QQProbe] %@: wrote to %lu location(s), %lu chars",
          name, (unsigned long)wrote, (unsigned long)[text length]);
}

static void QQProbeDump(void) {
    @autoreleasepool {
        NSLog(@"[QQProbe] dump starting");
        int count = objc_getClassList(NULL, 0);
        NSLog(@"[QQProbe] class count = %d", count);
        if (count <= 0) return;

        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (classes == NULL) return;
        objc_getClassList(classes, count);

        NSMutableString *all = [NSMutableString stringWithCapacity:(NSUInteger)count * 24];
        NSMutableString *meth = [NSMutableString stringWithCapacity:1024 * 256];
        NSArray *keys = QQProbeKeys();
        NSUInteger interestingCount = 0;

        for (int i = 0; i < count; i++) {
            const char *cname = class_getName(classes[i]);
            if (cname == NULL) continue;
            NSString *cn = [NSString stringWithUTF8String:cname];
            if (cn == nil) continue;

            [all appendFormat:@"%@\n", cn];

            BOOL interesting = NO;
            for (NSString *key in keys) {
                if ([cn rangeOfString:key].location != NSNotFound) {
                    interesting = YES;
                    break;
                }
            }
            if (!interesting) continue;

            interestingCount++;
            [meth appendFormat:@"\n=== %@ ===\n", cn];

            unsigned int mc = 0;
            Method *ms = class_copyMethodList(classes[i], &mc);
            if (ms != NULL) {
                for (unsigned int j = 0; j < mc; j++) {
                    [meth appendFormat:@"  -%s\n", sel_getName(method_getName(ms[j]))];
                }
                free(ms);
            }

            Class meta = object_getClass(classes[i]);
            if (meta != Nil && meta != classes[i]) {
                ms = class_copyMethodList(meta, &mc);
                if (ms != NULL) {
                    for (unsigned int j = 0; j < mc; j++) {
                        [meth appendFormat:@"  +%s\n", sel_getName(method_getName(ms[j]))];
                    }
                    free(ms);
                }
            }
        }
        free(classes);

        NSLog(@"[QQProbe] classes=%d interesting=%lu", count,
              (unsigned long)interestingCount);

        QQProbeWrite(@"qqclasses.txt", all);
        QQProbeWrite(@"qqmethods.txt", meth);

        NSArray *targets = @[
            @"BubbleBgManager", @"CFT_UITouchPayManageViewController",
            @"ImagesSplashView", @"PreviewSecretPictureViewController",
            @"QQAIOFontManager", @"QQAIOMsgModel", @"QQAIOTextModel",
            @"QQAIOTimeCell", @"QQAvatarView", @"QQCallkit", @"QQCountingLabel",
            @"QQDynamicDeviceInfo", @"QQFaceAssociateFrameView",
            @"QQFacePanelController", @"QQGroupDeliverGiftAnimationManager",
            @"QQGroupSettingModel", @"QQJSBridgeDevicePlugin",
            @"QQMessageModel", @"QQMessageRecallModule",
            @"QQRecommendViewController", @"QQWeatherView", @"QQWlxInfoUtils"
        ];
        NSMutableString *chk = [NSMutableString string];
        for (NSString *t in targets) {
            Class c = NSClassFromString(t);
            [chk appendFormat:@"%-42s %@\n", [t UTF8String],
                              (c != Nil) ? @"EXISTS" : @"-"];
        }
        QQProbeWrite(@"qqtargets.txt", chk);
        NSLog(@"[QQProbe] dump finished");
    }
}

static void QQProbeSchedule(void) {
    NSArray *delays = @[@5, @15, @30, @50];
    for (NSNumber *d in delays) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                QQProbeDump();
            });
    }
}

// Plain clang has no Logos, so this is a real constructor function.
__attribute__((constructor))
static void QQProbeInit(void) {
    @autoreleasepool {
        NSLog(@"[QQProbe] LOADED into %@ (home=%@)",
              [[NSBundle mainBundle] bundleIdentifier], NSHomeDirectory());
        QQProbeSchedule();
    }
}
