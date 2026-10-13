#import "BRURLProtocol.h"
#import "BRRouter.h"
#import "BRSession.h"
#import "BRLog.h"

NSString *const kBRInternalKey = @"BRInternalMarker";

// ★ 递归保护（线程级）
//   风险场景：我们抓取时发出的请求可能又被 App 自带的 BiliURLProtocol 接受，
//   它再用自己的 NSURLSession 重发；如果它重建了 request，我们打在 request 上的
//   标记属性就会丢失，于是我们的协议又接手 → 无限递归。
//   所以除了 request 属性标记，再加一道「本线程正在抓取」的闸门。
static NSString *const kBRDepthKey = @"BRFetchDepth";

static int BRFetchDepth(void) {
    NSNumber *n = [[[NSThread currentThread] threadDictionary] objectForKey:kBRDepthKey];
    return n ? [n intValue] : 0;
}
static void BRSetFetchDepth(int d) {
    NSMutableDictionary *td = [[NSThread currentThread] threadDictionary];
    if (d <= 0) [td removeObjectForKey:kBRDepthKey];
    else [td setObject:@(d) forKey:kBRDepthKey];
}

// 需要接管的域名（与 PAC 覆盖范围一致；只做 API，不碰 CDN 大流量）
static NSArray *BRHandledHosts(void) {
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"api.bilibili.com", @"app.bilibili.com", @"api.bilibili.cn",
              @"app.bilibili.cn", @"api.bilibili.tv", @"app.bilibili.tv",
              @"interface.bilibili.com", @"interface.bilibili.tv",
              @"comment.bilibili.com", @"comment.bilibili.tv",
              @"bangumi.bilibili.com", @"space.bilibili.com",
              @"passport.bilibili.com", @"www.bilibili.com",
              @"account.bilibili.com", @"member.bilibili.com",
              @"api.live.bilibili.com", @"live.bilibili.com",
              @"api.vc.bilibili.com", @"api.biliapi.net", @"api.biliapi.com"];
    });
    return a;
}

BOOL BRIsBiliHost(NSString *host) {
    if (![host length]) return NO;
    NSString *h = [host lowercaseString];
    for (NSString *d in BRHandledHosts()) {
        if ([h isEqualToString:d]) return YES;
    }
    return NO;
}

// 图片/视频 CDN 不接管（除非要改写 pic 字段，那是响应侧的事）
static BOOL BRIsImageHost(NSString *host) {
    if (![host length]) return NO;
    NSString *h = [host lowercaseString];
    return ([h hasSuffix:@"hdslb.com"] || [h hasSuffix:@"bilivideo.com"] ||
            [h hasSuffix:@"acgvideo.com"] || [h hasSuffix:@"biliapi.net"]);
}

// ---------------------------------------------------------------- 内部抓取

@implementation BRURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // ① 本线程正在抓取中 —— 一律放行（递归闸门）
    if (BRFetchDepth() > 0) return NO;

    // ② 我们自己发出的请求 —— 放行（request 上的标记属性）
    if ([NSURLProtocol propertyForKey:kBRInternalKey inRequest:request] != nil) return NO;

    NSString *host = [[request URL] host];
    if (![host length]) return NO;

    // ② 只接管 API 域名
    if (!BRIsBiliHost(host)) return NO;

    // ③ 图片/视频 CDN 直接放行（性能考虑）
    if (BRIsImageHost(host)) return NO;

    // ④ 带 HTTPBodyStream 的请求不接管 —— 流无法重放（会破坏上传）
    if ([request HTTPBodyStream] != nil) return NO;

    // ⑤ 已经是新接口的请求放行，避免重复处理
    NSString *path = [[request URL] path];
    if ([path hasPrefix:@"/x/web-interface/wbi/"] ||
        [path hasPrefix:@"/x/player/wbi/"] ||
        [path hasPrefix:@"/x/v2/reply/wbi/"]) {
        return NO;
    }

    // ⑥ www.bilibili.com 上既有接口也有网页 —— 只接管接口路径，
    //    否则会把 HTML 页面也重抓一遍（浪费且可能破坏 Cookie/跳转）
    if ([host isEqualToString:@"www.bilibili.com"]) {
        if (!([path hasPrefix:@"/index/"] || [path hasPrefix:@"/x/"])) return NO;
    }
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [[a URL] isEqual:[b URL]];
}

- (void)startLoading {
    NSURLRequest *req = [self request];
    BRRoute *route = [BRRouter routeForRequest:req];

    if (route == nil || route.url == nil) {
        // 没有路由规则 —— 用内部请求原样转发（避免被自己再拦一次）
        [self fetchAndDeliverURL:[[req URL] absoluteString] route:nil];
        return;
    }

    if (route.drop) {
        // 明确丢弃（例如映射丢失的假 ID，不能当真 ID 去请求）
        BRDBG(@"丢弃请求 %@（%@）", [[req URL] path], route.note);
        NSHTTPURLResponse *r = [NSClassFromString(@"NSHTTPURLResponse") alloc]
            initWithURL:[req URL] statusCode:200 HTTPVersion:@"HTTP/1.1"
            headerFields:@{@"Content-Type": @"application/json"}];
        NSString *body = @"{\"code\":-404,\"message\":\"not found\",\"data\":null}";
        [self.client URLProtocol:self didReceiveResponse:r
              cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:[body dataUsingEncoding:NSUTF8StringEncoding]];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }

    BRINFO(@"%@ -> %@", [[req URL] path], [route.url length] > 130 ?
          [[route.url substringToIndex:130] stringByAppendingString:@"…"] : route.url);

    [self fetchAndDeliverURL:route.url route:route];
}

- (void)stopLoading {
    // 同步抓取无法中断；这里只做标记
}

// 真正发请求：用带标记的请求走 NSURLConnection，并在响应侧做改写
- (void)fetchAndDeliverURL:(NSString *)urlStr route:(BRRoute *)route {
    NSURLRequest *orig = [self request];
    NSString *method = [orig HTTPMethod] ?: @"GET";
    NSData *body = [orig HTTPBody];
    NSDictionary *origHeaders = [orig allHTTPHeaderFields];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSURL *u = [NSURL URLWithString:urlStr];
            if (u == nil) {
                [self finishWithError:[NSError errorWithDomain:@"BR" code:-1 userInfo:nil]];
                return;
            }
            NSMutableURLRequest *r = [NSClassFromString(@"NSMutableURLRequest") requestWithURL:u];
            [r setTimeoutInterval:12];
            [r setHTTPMethod:method];
            if ([body length]) [r setHTTPBody:body];

            // ★ 统一套上风控请求头
            NSString *ua = route.ua;   // 路由可指定 UA（搜索要浏览器 UA、登录要 BiliDroid）
            NSDictionary *h = [BRSession headersForUA:ua];
            for (NSString *k in h) [r setValue:[h objectForKey:k] forHTTPHeaderField:k];
            if (route.extraHeaders) {
                for (NSString *k in route.extraHeaders)
                    [r setValue:[route.extraHeaders objectForKey:k] forHTTPHeaderField:k];
            }
            // 转发原请求里我们没覆盖的头（Cookie 除外，统一管理）
            for (NSString *k in origHeaders) {
                if ([k caseInsensitiveCompare:@"Cookie"] == NSOrderedSame) continue;
                if ([r valueForHTTPHeaderField:k] == nil)
                    [r setValue:[origHeaders objectForKey:k] forHTTPHeaderField:k];
            }
            // 匿名接口不带任何 Cookie（含 buvid3）——否则评论只返回 3 条
            if (!route.anonymous) {
                NSString *ck = [BRSession cookie];
                NSString *extraCookie = route.extraCookie;
                if ([extraCookie length]) {
                    ck = [ck length] ? [NSString stringWithFormat:@"%@; %@", extraCookie, ck]
                                     : extraCookie;
                }
                if ([ck length]) [r setValue:ck forHTTPHeaderField:@"Cookie"];
            }

            // ★ 打标记 —— 否则会被自己的 canInitWithRequest: 再拦一次，无限递归
            NSMutableURLRequest *marked = [r mutableCopy];
            [NSURLProtocol setProperty:@YES forKey:kBRInternalKey inRequest:marked];

            [BRSession throttle];
            NSHTTPURLResponse *resp = nil;
            NSError *err = nil;
            BRSetFetchDepth(BRFetchDepth() + 1);      // 抬起闸门
            // ★ 不能用 [NSURLConnection ...] —— iOS 上它的 ObjC 类符号在
            //   dlopen 时解析不到，会让整个 dylib 被卸载。
            Class _brConnCls = NSClassFromString(@"NSURLConnection");
            NSData *data = (_brConnCls ? [_brConnCls sendSynchronousRequest:marked
                                                 returningResponse:&resp error:&err] : nil);
            BRSetFetchDepth(BRFetchDepth() - 1);      // 放下闸门

            if (data == nil && err != nil) {
                BRERR(@"上游失败 %@ (%@)", u.host, [err localizedDescription]);
                [self finishWithError:err];
                return;
            }

            NSInteger code = [resp statusCode];
            if (code == 412) {
                BRERR(@"上游 412（风控）%@", u.path);
                // 退避，避免连续撞墙
                [NSThread sleepForTimeInterval:1.2];
            }

            // ---- 响应改写 ----
            NSData *out = data;
            if (route != nil && [data length]) {
                out = [BRRouter convertResponse:data forRoute:route];
                if (out == nil) out = data;
            }

            // ---- 回给上层 ----
            NSMutableDictionary *hdrs = [NSMutableDictionary dictionary];
            NSDictionary *rh = [resp allHeaderFields];
            for (NSString *k in rh) {
                NSString *lk = [k lowercaseString];
                // Content-Length 会因改写而变化，必须丢掉让系统重算
                if ([lk isEqualToString:@"content-length"]) continue;
                [hdrs setObject:[rh objectForKey:k] forKey:k];
            }
            if ([hdrs objectForKey:@"Content-Type"] == nil)
                [hdrs setObject:@"application/json; charset=utf-8" forKey:@"Content-Type"];

            NSHTTPURLResponse *newResp = [NSClassFromString(@"NSHTTPURLResponse") alloc]
                initWithURL:[orig URL]
                 statusCode:(code > 0 ? code : 200)
                HTTPVersion:@"HTTP/1.1"
               headerFields:hdrs];

            [self.client URLProtocol:self didReceiveResponse:newResp
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [self.client URLProtocol:self didLoadData:(out ? out : [NSData data])];
            [self.client URLProtocolDidFinishLoading:self];
        }
    });
}

- (void)finishWithError:(NSError *)err {
    if (err == nil) err = [NSError errorWithDomain:@"BR" code:-1
                                          userInfo:@{NSLocalizedDescriptionKey: @"请求失败"}];
    [self.client URLProtocol:self didFailWithError:err];
}

@end
