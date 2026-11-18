// QQProbe - read-only probe
//
// Dumps the ObjC runtime of the QQ process so we can build the
// "QQHelper feature -> QQ 6.2 class name" mapping.
//
// Safety:
//   * only calls objc_getClassList / class_copyMethodList (read only)
//   * only writes /tmp/qqclasses.txt, /tmp/qqmethods.txt, /tmp/qqtargets.txt
//   * never touches QQ's sandbox, data or preferences
//   * hooks nothing, changes no behaviour

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSArray *QQProbeKeys(void) {
    static NSArray *k = nil;
    if (k == nil) {
        k = @[@"Recall", @"Revoke", @"Message", @"Msg", @"Bubble", @"Font",
              @"Pendant", @"Avatar", @"Weather", @"Splash", @"Gift", @"Face",
              @"Emoji", @"Time", @"Level", @"Pay", @"Menu", @"AIO", @"Ad",
              @"Setting", @"Panel", @"Cell", @"Label"];
    }
    return k;
}

static void QQProbeWrite(NSString *name, NSString *text) {
    NSString *path = [@"/tmp" stringByAppendingPathComponent:name];
    NSError *err = nil;
    BOOL ok = [text writeToFile:path atomically:YES
                       encoding:NSUTF8StringEncoding error:&err];
    NSLog(@"[QQProbe] write %@ %@ (%lu chars)",
          name, ok ? @"OK" : @"FAIL", (unsigned long)[text length]);
}

static void QQProbeDump(void) {
    @autoreleasepool {
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) {
            NSLog(@"[QQProbe] objc_getClassList returned %d", count);
            return;
        }

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
    }
}

static void QQProbeSchedule(void) {
    NSArray *delays = @[@10, @25, @45];
    for (NSNumber *d in delays) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                QQProbeDump();
            });
    }
}

%ctor {
    @autoreleasepool {
        NSLog(@"[QQProbe] LOADED into %@", [[NSBundle mainBundle] bundleIdentifier]);
        QQProbeSchedule();
    }
}
