#import "BRStore.h"
#import "BRLog.h"

// 真 ID -> 假 ID（保证同一真 ID 每次拿到同一假 ID）
static NSMutableDictionary *gFakeByRealAid = nil;   // @(real) -> @(fake)
static NSMutableDictionary *gRealByFakeAid = nil;   // @(fake) -> @(real)
static long long gNextFakeAid = BR_FAKE_AID_BASE;

static NSMutableDictionary *gFakeByRealCid = nil;
static NSMutableDictionary *gRealByFakeCid = nil;
static long long gNextFakeCid = BR_FAKE_CID_BASE;

static NSMutableDictionary *gFakeByRealMid = nil;
static NSMutableDictionary *gRealByFakeMid = nil;
static long long gNextFakeMid = BR_FAKE_AID_BASE;

static NSMutableDictionary *gAidByCid = nil;        // @(realCid) -> @(realAid)

static NSLock *gLock = nil;

static NSString *BRWorkDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *cands = [NSArray arrayWithObjects:@"/var/mobile/bilifix", @"/tmp", nil];
    for (NSString *d in cands) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:d isDirectory:&isDir] || !isDir) {
            [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        if ([fm isWritableFileAtPath:d]) return d;
    }
    NSString *home = NSHomeDirectory();
    if (home) {
        NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
        [fm createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:NULL];
        if ([fm isWritableFileAtPath:docs]) return docs;
    }
    return NSTemporaryDirectory();
}

static NSString *BRPath(NSString *name) {
    // ★ 持久化目录不要用 Library/Caches —— 系统存储紧张时会清掉它，
    //   而映射一丢就会出现「详情页只有封面、标题空白」这类症状。
    return [BRWorkDir() stringByAppendingPathComponent:name];
}

// 行格式：real=fake
static void BRLoadMap(NSString *file, NSMutableDictionary *fakeByReal,
                      NSMutableDictionary *realByFake, long long *next) {
    NSString *txt = [NSString stringWithContentsOfFile:BRPath(file)
                                              encoding:NSUTF8StringEncoding error:NULL];
    if (txt == nil) return;
    NSArray *lines = [txt componentsSeparatedByString:@"\n"];
    long long cnt = 0;
    for (NSString *ln in lines) {
        NSString *s = [ln stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([s length] == 0) continue;
        NSRange eq = [s rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        long long real = [[s substringToIndex:eq.location] longLongValue];
        long long fake = [[s substringFromIndex:eq.location + 1] longLongValue];
        if (real <= 0 || fake <= 0) continue;
        [fakeByReal setObject:@(fake) forKey:@(real)];
        [realByFake setObject:@(real) forKey:@(fake)];
        if (fake >= *next) *next = fake + 1;
        cnt++;
    }
    if (cnt) BRINFO(@"已加载 %@ 映射 %lld 条", file, cnt);
}

static void BRSaveMap(NSString *file, NSMutableDictionary *fakeByReal) {
    NSMutableString *sb = [NSMutableString stringWithCapacity:4096];
    NSArray *keys = [[fakeByReal allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *k in keys) {
        [sb appendFormat:@"%lld=%lld\n", [k longLongValue],
         [[fakeByReal objectForKey:k] longLongValue]];
    }
    // ★ 必须「尽快落盘」：用户下一秒就可能点进播放页，
    //   而播放页完全依赖这张表把假 ID 还原成真值。节流落盘会丢。
    NSError *err = nil;
    if (![sb writeToFile:BRPath(file) atomically:YES
                encoding:NSUTF8StringEncoding error:&err]) {
        BRERR(@"写 %@ 失败: %@", file, err);
    }
}

@implementation BRStore

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [[NSLock alloc] init];
        gFakeByRealAid = [[NSMutableDictionary alloc] init];
        gRealByFakeAid = [[NSMutableDictionary alloc] init];
        gFakeByRealCid = [[NSMutableDictionary alloc] init];
        gRealByFakeCid = [[NSMutableDictionary alloc] init];
        gFakeByRealMid = [[NSMutableDictionary alloc] init];
        gRealByFakeMid = [[NSMutableDictionary alloc] init];
        gAidByCid = [[NSMutableDictionary alloc] init];

        BRLoadMap(@"aidmap.txt", gFakeByRealAid, gRealByFakeAid, &gNextFakeAid);
        BRLoadMap(@"cidmap.txt", gFakeByRealCid, gRealByFakeCid, &gNextFakeCid);
        BRLoadMap(@"midmap.txt", gFakeByRealMid, gRealByFakeMid, &gNextFakeMid);
        {
            // cid2aid.txt 的行格式是 cid=aid，与其它映射表同构，
            // 这里用一次性容器接住反向表和计数器（不用复合字面量取址，避免可移植性问题）
            long long dummyNext = 0;
            BRLoadMap(@"cid2aid.txt", gAidByCid, [[NSMutableDictionary alloc] init], &dummyNext);
        }
    });
}

+ (void)flush {
    [gLock lock];
    BRSaveMap(@"aidmap.txt", gFakeByRealAid);
    BRSaveMap(@"cidmap.txt", gFakeByRealCid);
    BRSaveMap(@"midmap.txt", gFakeByRealMid);
    BRSaveMap(@"cid2aid.txt", gAidByCid);
    [gLock unlock];
}

#pragma mark - aid

+ (long long)fakeAidForReal:(long long)real {
    if (real <= 0) return real;
    // 小于段位的一律原样返回（真实老视频，界面上显示的就是真实 AV 号）
    if (real < BR_FAKE_AID_BASE) return real;

    [gLock lock];
    NSNumber *got = [gFakeByRealAid objectForKey:@(real)];
    if (got) {
        long long f = [got longLongValue];
        [gLock unlock];
        return f;
    }
    long long fake = gNextFakeAid++;
    if (fake == BR_SENTINEL_ID) fake = gNextFakeAid++;   // 跳过哨兵
    [gFakeByRealAid setObject:@(fake) forKey:@(real)];
    [gRealByFakeAid setObject:@(real) forKey:@(fake)];
    BRSaveMap(@"aidmap.txt", gFakeByRealAid);
    [gLock unlock];
    return fake;
}

+ (long long)realAidForFake:(long long)fake {
    if (fake <= 0) return fake;
    if (fake < BR_FAKE_AID_BASE) return fake;      // 真实 ID，原样
    [gLock lock];
    NSNumber *got = [gRealByFakeAid objectForKey:@(fake)];
    [gLock unlock];
    if (got) return [got longLongValue];
    // ★ 落在假区间却查不到 —— 说明映射丢了。
    //   这时**不能**把它当真 aid 去请求，否则会命中一个毫不相干的老视频
    //   （症状：详情页只有封面、标题空白、播放/弹幕/收藏全是 0）。
    //   返回 0 让上层放弃这次请求。
    return 0;
}

+ (BOOL)looksLikeFakeAid:(long long)v {
    return (v >= BR_FAKE_AID_BASE && v < gNextFakeAid);
}

#pragma mark - cid

+ (long long)fakeCidForReal:(long long)real {
    if (real <= 0) return real;
    if (real < BR_FAKE_CID_BASE) return real;
    [gLock lock];
    NSNumber *got = [gFakeByRealCid objectForKey:@(real)];
    if (got) { long long f = [got longLongValue]; [gLock unlock]; return f; }
    long long fake = gNextFakeCid++;
    [gFakeByRealCid setObject:@(fake) forKey:@(real)];
    [gRealByFakeCid setObject:@(real) forKey:@(fake)];
    BRSaveMap(@"cidmap.txt", gFakeByRealCid);
    [gLock unlock];
    return fake;
}

+ (long long)realCidForFake:(long long)fake {
    if (fake <= 0) return fake;
    if (fake < BR_FAKE_CID_BASE) return fake;
    [gLock lock];
    NSNumber *got = [gRealByFakeCid objectForKey:@(fake)];
    [gLock unlock];
    return got ? [got longLongValue] : fake;
}

#pragma mark - mid

+ (long long)fakeMidForReal:(long long)real {
    if (real <= 0) return real;
    if (real < BR_FAKE_AID_BASE) return real;
    [gLock lock];
    NSNumber *got = [gFakeByRealMid objectForKey:@(real)];
    if (got) { long long f = [got longLongValue]; [gLock unlock]; return f; }
    long long fake = gNextFakeMid++;
    [gFakeByRealMid setObject:@(fake) forKey:@(real)];
    [gRealByFakeMid setObject:@(real) forKey:@(fake)];
    BRSaveMap(@"midmap.txt", gFakeByRealMid);
    [gLock unlock];
    return fake;
}

+ (long long)realMidForFake:(long long)fake {
    if (fake <= 0) return fake;
    if (fake < BR_FAKE_AID_BASE) return fake;
    [gLock lock];
    NSNumber *got = [gRealByFakeMid objectForKey:@(fake)];
    [gLock unlock];
    return got ? [got longLongValue] : 0;
}

#pragma mark - cid -> aid

+ (void)rememberCid:(long long)cid forAid:(long long)aid {
    if (cid <= 0 || aid <= 0) return;
    [gLock lock];
    if ([gAidByCid objectForKey:@(cid)] == nil) {
        [gAidByCid setObject:@(aid) forKey:@(cid)];
        BRSaveMap(@"cid2aid.txt", gAidByCid);
    }
    [gLock unlock];
}

+ (long long)aidForCid:(long long)cid {
    [gLock lock];
    NSNumber *got = [gAidByCid objectForKey:@(cid)];
    [gLock unlock];
    return got ? [got longLongValue] : 0;
}

@end
