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
    NSArray *cands = [NSArray arrayWithObjects:@"/var/mobile/bilifix", @"/tmp", nil];
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

@implementation BRSession+ (NSString *)appUA    { return @"BiliApp/434 (iPhone; iOS 7.1.2; Scale/2.00)"; }

/* ==== 静态辅助函数（两个分组都需要）==== */
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
+ (NSString *)md5:(NSString *)s {
    if (![s length]) return @"";
    const char *c = [s UTF8String];
    unsigned char d[BRCC_MD5_DIGEST_LENGTH];
    BRCC_MD5(c, (BRCC_LONG)strlen(c), d);
    NSMutableString *o = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < BRCC_MD5_DIGEST_LENGTH; i++) [o appendFormat:@"%02x", d[i]];
    return o;
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
+ (void)throttle {
    [gThrottleLock lock];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval wait = kMinInterval - (now - gLastUpstream);
    gLastUpstream = now + (wait > 0 ? wait : 0);
    [gThrottleLock unlock];
    if (wait > 0) [NSThread sleepForTimeInterval:wait];
}
+ (NSData *)rawGet:(NSString *)url ua:(NSString *)ua cookie:(NSString *)cookie {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setTimeoutInterval:10];
    NSDictionary *h = [self headersForUA:ua];
    for (NSString *k in h) [req setValue:[h objectForKey:k] forHTTPHeaderField:k];
    if ([cookie length]) [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    [self throttle];
    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *d = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (d == nil) BRERR(@"rawGet 失败 %@ (%@)", url, err);
    return d;
}

/* ---- 以下为占位空壳（本组不含真实实现）---- */
+ (void)bootstrap
{
}

+ (void)warmUp
{
}

+ (void)fetchBuvid
{
}

+ (void)fetchWbiKeys
{
}

+ (NSString *)buvid3
{
    return nil;
}

+ (NSString *)buvid4
{
    return nil;
}

+ (NSString *)bNut
{
    return nil;
}

+ (BOOL)hasUserCookie
{
    return 0;
}

+ (void)setUserCookie:(NSString *)c
{
}

+ (NSString *)cookie
{
    return nil;
}

+ (NSString *)chromeUA
{
    return nil;
}

@end
