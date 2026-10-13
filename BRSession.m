#import "BRSession.h"
#import "BRLog.h"
#import "BRCrypto.h"   // CommonCrypto 改成运行时 dlsym 解析（见该文件顶部说明）
#include <string.h>


static NSString *gBuvid3 = nil;
static NSString *gBuvid4 = nil;
static NSString *gBNut = nil;
static NSString *gUserCookie = nil;
static NSString *gWbiMixin = nil;

// wbi 固定重排表（官方 64 位序）
static const int kWbiTab[64] = {
    46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,
    27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,
    37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,
    22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52
};
// nav 被风控时用的兜底 mixin key
static NSString *const kWbiFallback = @"604f662d63f4ee19c94bd8ac0de3f84d";

static NSLock *gThrottleLock = nil;
static NSTimeInterval gLastUpstream = 0;
static const NSTimeInterval kMinInterval = 0.12;   // 120ms

static NSString *BRWorkPath(NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // ★ 同 BRStore：App 自己的 Documents 在沙盒内一定可写，
    //   而 /var/mobile/bilifix 对沙盒进程是写不进去的
    //   （isWritableFileAtPath: 只看 POSIX 权限、不看沙盒规则）。
    //   不改的话后果是：登录后 Cookie 存不下来，下次打开又要重新登录。
    NSString *brHome2 = NSHomeDirectory();
    NSString *brDocs2 = brHome2 ? [brHome2 stringByAppendingPathComponent:@"Documents"] : nil;
    NSMutableArray *cands = [NSMutableArray array];
    if (brDocs2 != nil) [cands addObject:brDocs2];
    [cands addObject:@"/var/mobile/bilifix"];
    [cands addObject:@"/tmp"];
    for (NSString *d in cands) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:d isDirectory:&isDir] || !isDir) {
            [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        if ([fm isWritableFileAtPath:d]) return [d stringByAppendingPathComponent:name];
    }
    NSString *home = NSHomeDirectory();
    if (home) {
        NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
        [fm createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:NULL];
        return [docs stringByAppendingPathComponent:name];
    }
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

@implementation BRSession

+ (void)bootstrap {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gThrottleLock = [[NSLock alloc] init];
        gBNut = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];

        // 用户导入的登录态（SESSDATA 三件套）
        NSString *ck = [NSString stringWithContentsOfFile:BRWorkPath(@"usercookie.txt")
                                                 encoding:NSUTF8StringEncoding error:NULL];
        if (ck) {
            gUserCookie = [ck stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([gUserCookie length]) BRINFO(@"已载入用户 Cookie（%lu 字节）", (unsigned long)[gUserCookie length]);
        }
    });
}

+ (void)warmUp {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            @autoreleasepool {
                [self fetchBuvid];
                [self fetchWbiKeys];
            }
        });
    });
}

#pragma mark - buvid

+ (void)fetchBuvid {
    // ★ 预热请求本身也要带全套指纹，否则拿回来的可能是脏 buvid
    NSString *u = @"https://api.bilibili.com/x/frontend/finger/spi";
    NSData *d = [self rawGet:u ua:[self chromeUA] cookie:nil];
    if (d == nil) { BRERR(@"取 buvid 失败"); return; }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    NSDictionary *data = [j isKindOfClass:[NSDictionary class]] ? [j objectForKey:@"data"] : nil;
    if (![data isKindOfClass:[NSDictionary class]]) { BRERR(@"buvid 响应异常"); return; }
    // ★ 两个都要：只带 buvid3 在不少接口上照样 -352 / -412
    gBuvid3 = [data objectForKey:@"b_3"];
    gBuvid4 = [data objectForKey:@"b_4"];
    BRINFO(@"buvid3=%@ buvid4=%@", gBuvid3 ? @"✓" : @"✗", gBuvid4 ? @"✓" : @"✗");
}

+ (void)fetchWbiKeys {
    NSString *u = @"https://api.bilibili.com/x/web-interface/nav";
    NSData *d = [self rawGet:u ua:[self chromeUA] cookie:[self cookie]];
    if (d == nil) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    NSDictionary *data = [j isKindOfClass:[NSDictionary class]] ? [j objectForKey:@"data"] : nil;
    NSDictionary *wi = [data isKindOfClass:[NSDictionary class]] ? [data objectForKey:@"wbi_img"] : nil;
    NSString *img = [wi objectForKey:@"img_url"];
    NSString *sub = [wi objectForKey:@"sub_url"];
    if (![img isKindOfClass:[NSString class]] || ![sub isKindOfClass:[NSString class]]) {
        BRERR(@"nav 没给 wbi_img，将用兜底 key");
        return;
    }
    NSString *a = [[img lastPathComponent] stringByDeletingPathExtension];
    NSString *b = [[sub lastPathComponent] stringByDeletingPathExtension];
    NSString *raw = [a stringByAppendingString:b];
    if ([raw length] < 64) return;
    NSMutableString *mix = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 64; i++) {
        unichar c = [raw characterAtIndex:kWbiTab[i]];
        [mix appendFormat:@"%C", c];
    }
    gWbiMixin = [mix substringToIndex:32];
    BRINFO(@"wbi mixin 已就绪");
}

#pragma mark - 身份

+ (NSString *)buvid3 { return gBuvid3; }
+ (NSString *)buvid4 { return gBuvid4; }
+ (NSString *)bNut  { return gBNut; }
+ (BOOL)hasUserCookie { return [gUserCookie length] > 0; }

+ (void)setUserCookie:(NSString *)c {
    gUserCookie = [c copy];
    [gUserCookie writeToFile:BRWorkPath(@"usercookie.txt") atomically:YES
                    encoding:NSUTF8StringEncoding error:NULL];
}

+ (NSString *)cookie {
    NSMutableArray *parts = [NSMutableArray array];
    if ([gUserCookie length]) [parts addObject:gUserCookie];
    if ([gBuvid3 length]) [parts addObject:[NSString stringWithFormat:@"buvid3=%@", gBuvid3]];
    if ([gBuvid4 length]) [parts addObject:[NSString stringWithFormat:@"buvid4=%@", gBuvid4]];
    if ([gBNut length])   [parts addObject:[NSString stringWithFormat:@"b_nut=%@", gBNut]];
    return [parts componentsJoinedByString:@"; "];
}

#pragma mark - 请求头

+ (NSString *)chromeUA {
    return @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/122.0.6261.95 Safari/537.36";
}
+ (NSString *)appUA    { return @"BiliApp/434 (iPhone; iOS 7.1.2; Scale/2.00)"; }
+ (NSString *)searchUA { return @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_0 like Mac OS X) "
                                 "AppleWebKit/536.26"; }
+ (NSString *)loginUA  { return @"Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android "
                                 "model/android_hd mobi_app/android_hd build/2001100 channel/master"; }

+ (NSDictionary *)headersForUA:(NSString *)ua {
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    BOOL custom = ([ua length] > 0);
    [h setObject:(custom ? ua : [self chromeUA]) forKey:@"User-Agent"];
    [h setObject:@"application/json, text/plain, */*" forKey:@"Accept"];
    [h setObject:@"zh-CN,zh;q=0.9,en;q=0.8" forKey:@"Accept-Language"];
    [h setObject:@"https://www.bilibili.com/" forKey:@"Referer"];
    [h setObject:@"https://www.bilibili.com" forKey:@"Origin"];
    // ★ 只设 UA、不带 Sec-Ch-Ua 系列，平时能过，请求一密集就开始 412。
    //   但「客户端 UA + Chrome 的 Sec-Ch-Ua」混搭比不设还糟 —— 所以成套切换。
    if (!custom) {
        [h setObject:@"\"Chromium\";v=\"122\", \"Not(A:Brand\";v=\"24\", \"Google Chrome\";v=\"122\""
              forKey:@"Sec-Ch-Ua"];
        [h setObject:@"\"Windows\"" forKey:@"Sec-Ch-Ua-Platform"];
        [h setObject:@"?0" forKey:@"Sec-Ch-Ua-Mobile"];
    }
    return h;
}

#pragma mark - 摘要

+ (NSString *)md5:(NSString *)s {
    if (![s length]) return @"";
    const char *c = [s UTF8String];
    unsigned char d[BRCC_MD5_DIGEST_LENGTH];
    BRCC_MD5(c, (BRCC_LONG)strlen(c), d);
    NSMutableString *o = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < BRCC_MD5_DIGEST_LENGTH; i++) [o appendFormat:@"%02x", d[i]];
    return o;
}

#pragma mark - wbi 签名

// RFC3986（空格 -> %20）。wbi 用这一套。
static NSString *BRRFC3986(NSString *s) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *cs = [NSMutableCharacterSet alphanumericCharacterSet];
        [cs addCharactersInString:@"-._~"];
        allowed = cs;
    });
    NSString *e = [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return e ? e : @"";
}

+ (NSString *)wbiSignURL:(NSString *)url {
    if (![url length]) return url;
    NSRange q = [url rangeOfString:@"?"];
    if (q.location == NSNotFound) return url;
    NSString *base = [url substringToIndex:q.location];
    NSString *query = [url substringFromIndex:q.location + 1];

    // ★ 调用方传来的值必须已经是「未编码」的原始值 ——
    //   wbi_sign 会对每个值再编码一次，预先编码会导致 % 变成 %25（双重编码），
    //   服务端收到乱码，返回一堆与关键词无关的泛化结果。
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *kv in [query componentsSeparatedByString:@"&"]) {
        if ([kv length] == 0) continue;
        [pairs addObject:kv];
    }
    NSString *wts = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];
    [pairs addObject:[NSString stringWithFormat:@"wts=%@", wts]];
    [pairs sortUsingSelector:@selector(compare:)];

    NSMutableString *signed_ = [NSMutableString string];
    for (NSUInteger i = 0; i < [pairs count]; i++) {
        if (i) [signed_ appendString:@"&"];
        NSString *kv = [pairs objectAtIndex:i];
        NSRange eq = [kv rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            [signed_ appendString:kv];
        } else {
            NSString *k = [kv substringToIndex:eq.location];
            NSString *v = [kv substringFromIndex:eq.location + 1];
            [signed_ appendFormat:@"%@=%@", k, BRRFC3986(v)];
        }
    }
    NSString *mixin = [gWbiMixin length] ? gWbiMixin : kWbiFallback;
    NSString *rid = [self md5:[signed_ stringByAppendingString:mixin]];
    return [NSString stringWithFormat:@"%@?%@&w_rid=%@", base, signed_, rid];
}

#pragma mark - APP 签名

// Java URLEncoder.encode(s, "UTF-8") 语义：
//   保留 A-Z a-z 0-9 . - * _   空格 -> +   其余 UTF-8 字节 %XX（大写）
// ⚠️ 与 wbi 的 RFC3986 是两套编码，绝不能共用。
+ (NSString *)javaURLEncode:(NSString *)s {
    if (![s length]) return @"";
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *b = [d bytes];
    NSMutableString *o = [NSMutableString stringWithCapacity:[d length] * 2];
    for (NSUInteger i = 0; i < [d length]; i++) {
        unsigned char c = b[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '.' || c == '-' || c == '*' || c == '_') {
            [o appendFormat:@"%c", c];
        } else if (c == ' ') {
            [o appendString:@"+"];
        } else {
            [o appendFormat:@"%%%02X", c];
        }
    }
    return o;
}

+ (NSString *)appSignWithParams:(NSDictionary *)params
                         appkey:(NSString *)appkey
                         appsec:(NSString *)appsec {
    NSMutableDictionary *p = [NSMutableDictionary dictionaryWithDictionary:params];
    [p setObject:appkey forKey:@"appkey"];
    if ([p objectForKey:@"ts"] == nil) {
        [p setObject:[NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]]
              forKey:@"ts"];
    }
    NSArray *keys = [[p allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *sb = [NSMutableString string];
    for (NSUInteger i = 0; i < [keys count]; i++) {
        if (i) [sb appendString:@"&"];
        NSString *k = [keys objectAtIndex:i];
        id v = [p objectForKey:k];
        [sb appendFormat:@"%@=%@", k, [self javaURLEncode:
            [v isKindOfClass:[NSString class]] ? v : [v description]]];
    }
    // 末尾直接拼 appsec（没有分隔符），再取 md5
    return [self md5:[sb stringByAppendingString:appsec]];
}

#pragma mark - 限流

+ (void)throttle {
    [gThrottleLock lock];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval wait = kMinInterval - (now - gLastUpstream);
    gLastUpstream = now + (wait > 0 ? wait : 0);
    [gThrottleLock unlock];
    if (wait > 0) [NSThread sleepForTimeInterval:wait];
}

#pragma mark - 内部同步 GET（不走 NSURLProtocol，避免递归）

+ (NSData *)rawGet:(NSString *)url ua:(NSString *)ua cookie:(NSString *)cookie {
    // ★★ 这里绝不能直接写 [NSURLConnection ...] ——
    //    iOS 上 NSURLConnection 的实现位于 CFNetwork，而本插件用的是
    //    -undefined dynamic_lookup。dyld 在加载那一瞬间解析不到
    //    _OBJC_CLASS_$_NSURLConnection，dlopen 就返回 NULL，
    //    SubstrateLoader 随即把整个 dylib 卸载（构造函数一行都不执行）。
    //    改成 NSClassFromString 之后，符号表里只会有 _NSClassFromString
    //    （Foundation 的普通函数，一定能解析），类引用推迟到真正调用时。
    Class reqCls  = NSClassFromString(@"NSMutableURLRequest");
    Class connCls = NSClassFromString(@"NSURLConnection");
    if (reqCls == Nil || connCls == Nil) {
        BRERR(@"rawGet: 取不到 NSMutableURLRequest / NSURLConnection");
        return nil;
    }

    NSURL *u = [NSURL URLWithString:url];
    if (u == nil) return nil;

    id req = [reqCls requestWithURL:u];
    [req setTimeoutInterval:10];
    NSDictionary *h = [self headersForUA:ua];
    for (NSString *k in h) [req setValue:[h objectForKey:k] forHTTPHeaderField:k];
    if ([cookie length]) [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    [self throttle];

    id resp = nil;
    NSError *err = nil;
    NSData *d = [connCls sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (d == nil) BRERR(@"rawGet 失败 %@ (%@)", url, err);
    return d;
}

@end
