//
//  Tweak.xm —— BiloginalfX7  Alpha6.1（里程碑诊断版）
//
//  ── 为什么要有里程碑 ──────────────────────────────────────────
//  实测发现本 dylib 会被 dyld **加载后立即卸载**：
//      dyld: loaded:   .../BiloginalfX7.dylib
//      dyld: unloaded: .../BiloginalfX7.dylib
//  且紧接着 SubstrateLoader 调用了 dlerror() —— 说明 dlopen 返回 NULL。
//  符号绑定全部成功，所以只能是「初始化器执行时抛了异常」。
//
//  对策：
//    1) 不用 +load（它在 dyld 初始化最早期跑，抛异常会让整个 dlopen 失败），
//       改成 
//       %ctor 里显式调用 +bootstrap
//    2) 每个阶段都往 /tmp/br-milestone.txt 写一行 —— 走到哪一步一目了然
//    3) 整体套 @try/@catch，异常被捕获后 dlopen 就不会失败，dylib 得以保留
//  ─────────────────────────────────────────────────────────────
//
//  网络栈（静态分析 bili-universal 得出，并被探针实测证实）：
//      业务 API → BiliApiV2/V3 → APURLConnectionOperation（AFNetworking fork）
//               → -[NSURLConnection initWithRequest:delegate:]   ← 实测走这里
//               → BiliURLProtocol（App 自己注册的 NSURLProtocol）
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "BRCrypto.h"
#import "BRLogin.h"
#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRURLProtocol.h"
#import "BRRouter.h"

#pragma mark - 里程碑（完全独立，不依赖任何插件代码）

static void BRMark(const char *tag) {
    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %s\n",
                          [NSDate date], tag];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *paths = [NSArray arrayWithObjects:
            @"/tmp/br-milestone.txt",
            @"/var/mobile/br-milestone.txt", nil];
        for (NSString *p in paths) {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (fh != nil) {
                [fh seekToEndOfFile];
                [fh writeData:d];
                [fh closeFile];
            } else {
                [d writeToFile:p atomically:NO];
            }
        }
    } @catch (NSException *e) { }
}

#pragma mark - 兜底 hook：NSURLConnection 四个入口


#pragma mark - ★ 请求改写（把 BRRouter 的路由结果应用到 NSURLRequest 上）

// 返回改写后的请求；不需要改写时原样返回。
// 出任何问题都原样返回 —— 绝不能让插件的故障影响 App。

#pragma mark - ★ 响应改写代理

// 只截「收到数据」和「加载完成」两个回调，其余全部原样转发给真实 delegate。
// ★ NSURLConnection 对 delegate 是弱引用，代理对象必须被强持有，
//   否则出作用域就释放 → 悬垂指针 → 崩溃。
static NSMutableSet *gBRProxies = nil;
static NSLock *gBRProxyLock = nil;

static void BRHoldProxy(id px) {
    @try {
        if (px == nil) return;
        if (gBRProxyLock == nil) gBRProxyLock = [[NSLock alloc] init];
        [gBRProxyLock lock];
        if (gBRProxies == nil) gBRProxies = [[NSMutableSet alloc] init];
        [gBRProxies addObject:px];
        [gBRProxyLock unlock];
    } @catch (NSException *e) { }
}

static void BRReleaseProxy(id px) {
    @try {
        if (px == nil) return;
        [gBRProxyLock lock];
        [gBRProxies removeObject:px];
        [gBRProxyLock unlock];
    } @catch (NSException *e) { }
}

@interface BRDelegateProxy : NSObject
@property (nonatomic, strong) id        real;     // 真实 delegate（弱引用会挂，这里强持有）
@property (nonatomic, strong) BRRoute  *route;
@property (nonatomic, strong) NSMutableData *buf;
@property (nonatomic, assign) BOOL      converted; // 已转换过就不再重复
@end

@implementation BRDelegateProxy

- (BOOL)respondsToSelector:(SEL)sel {
    if ([super respondsToSelector:sel]) return YES;
    @try { return [_real respondsToSelector:sel]; } @catch (NSException *e) { return NO; }
}

// 没实现的方法统统转给真实 delegate
- (id)forwardingTargetForSelector:(SEL)sel {
    @try {
        if (_real != nil && [_real respondsToSelector:sel]) return _real;
    } @catch (NSException *e) { }
    return [super forwardingTargetForSelector:sel];
}

- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)d {
    @try {
        if (_buf == nil) _buf = [NSMutableData data];
        if (d != nil) [_buf appendData:d];
    } @catch (NSException *e) { }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)c {
    @try {
        NSData *out = _buf;
        if (!_converted && _route != nil && _buf.length) {
            _converted = YES;
            NSData *conv = [BRRouter convertResponse:_buf forRoute:_route];
            if (conv != nil) {
                out = conv;
                BRINFO(@"[改写] 响应 %@：%lu -> %lu 字节",
                      _route.kind ?: @"?", (unsigned long)_buf.length, (unsigned long)conv.length);
            }
        }
        if (out.length && [_real respondsToSelector:@selector(connection:didReceiveData:)])
            [_real connection:c didReceiveData:out];
        if ([_real respondsToSelector:@selector(connectionDidFinishLoading:)])
            [_real connectionDidFinishLoading:c];
        BRReleaseProxy(self);   // ★ 用完就放
    } @catch (NSException *e) {
        BRERR(@"[改写] 完成回调异常: %@", [e description]);
        @try {
            if ([_real respondsToSelector:@selector(connectionDidFinishLoading:)])
                [_real connectionDidFinishLoading:c];
        } @catch (NSException *e2) { }
    }
}

@end


#pragma mark - ★ 自检：主动发一个请求走 NSURLConnection，验证改写链路

// 只有存在 /tmp/br-selftest 时才跑（避免影响正常使用）
static void BRRunSelfTest(void) {
    @autoreleasepool {
        if (![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-selftest"]) return;
        BRINFO(@"[自检] ===== 开始 =====");

        // 挑一个 BRRouter 一定会改写的接口
        NSArray *urls = [NSArray arrayWithObjects:
            @"http://app.bilibili.com/x/v2/feed/index?build=4070&mobi_app=iphone&pn=1&ps=10",
            @"http://api.bilibili.com/x/v2/reply?type=1&oid=1&pn=1&ps=20",
            @"http://app.bilibili.com/x/v2/search?keyword=test&build=4070",
            // ★ 番剧（bangumi 路由）
            @"http://bangumi.bilibili.com/api/timeline_v2?type=1",
            // ★ 播放地址（playurl 路由）
            @"http://interface.bilibili.com/playurl?aid=170001&cid=279786&qn=32&platform=html5",
            // ★ 视频详情（验证 view_to_old 的字段提升）
            @"http://app.bilibili.com/x/web-interface/view?aid=170001",
            // ★ 分区（验证 archives/page/size）
            @"http://app.bilibili.com/x/v2/region?rid=1&pn=1&ps=20",
            nil];

        for (NSString *u in urls) {
            @try {
                NSURL *url = [NSClassFromString(@"NSURL") URLWithString:u];
                NSURLRequest *req = [NSClassFromString(@"NSURLRequest") requestWithURL:url
                                                     cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                 timeoutInterval:10];
                NSHTTPURLResponse *resp = nil;
                NSError *err = nil;
                NSData *d = [NSClassFromString(@"NSURLConnection") sendSynchronousRequest:req
                                                  returningResponse:&resp
                                                              error:&err];
                BRINFO(@"[自检] %@ => HTTP %ld, %lu 字节, err=%@",
                       [url path], (long)[resp statusCode],
                       (unsigned long)[d length], err ? @"有" : @"无");
                if ([d length]) {
                    NSString *head = [[NSString alloc] initWithData:
                        [d subdataWithRange:NSMakeRange(0, MIN((NSUInteger)160, [d length]))]
                        encoding:NSUTF8StringEncoding];
                    BRINFO(@"[自检] 响应开头: %@", head ?: @"(非 UTF8)");
                }
            } @catch (NSException *e) {
                BRINFO(@"[自检] %@ 异常: %@", u, [e description]);
            }
        }
        BRINFO(@"[自检] ===== 结束 =====");
    }
}

#define BRDIAG(...) BRLogWrite(@"[D] " __VA_ARGS__)

// ★ 改写路径会被多线程同时进入（App 请求 + warmUp 请求 + 自检），
//   而 BRRouter/BRStore/BRSession 里有惰性初始化的共享状态 —— 必须串行化。
//   用递归锁：万一内部又触发一次改写也不会自锁死。
static NSRecursiveLock *gBRRewriteLock = nil;

static void BRLockInit(void) {
    if (gBRRewriteLock == nil) {
        @synchronized ([NSObject class]) {
            if (gBRRewriteLock == nil) gBRRewriteLock = [[NSRecursiveLock alloc] init];
        }
    }
}

// 带 route 输出的版本：同步/异步路径都需要拿到 route 才能转换响应

#pragma mark - ★ 登录请求参数补齐 + 重签（照搬 5.9 参考实现）

#define BR_LOGIN_APPKEY  @"dfca71928277209b"
#define BR_LOGIN_APPSEC  @"b5475a8825547a4fc26c7d518eaaa02e"
#define BR_LOGIN_BUILD   @"2001100"
#define BR_LOGIN_STATS   @"{\"appId\":5,\"platform\":3,\"version\":\"2.0.1\",\"abtest\":\"\"}"

// 把 query 拆成有序的键值对（保留原始未解码值）
static NSArray *BRQueryPairs(NSString *q) {
    NSMutableArray *out = [NSMutableArray array];
    if (![q length]) return out;
    for (NSString *part in [q componentsSeparatedByString:@"&"]) {
        if (![part length]) continue;
        NSRange r = [part rangeOfString:@"="];
        if (r.location == NSNotFound) [out addObject:@[part, @""]];
        else [out addObject:@[[part substringToIndex:r.location],
                              [part substringFromIndex:r.location + 1]]];
    }
    return out;
}

static NSString *BRURLDecode(NSString *s) {
    return [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: s;
}

// 返回补齐后的 query；不该处理时返回 nil
static NSString *BREnhanceLoginQuery(NSString *path, NSString *query, NSString *buvid) {
    @try {
        NSString *low = [path lowercaseString];
        if ([low rangeOfString:@"login"].location == NSNotFound &&
            [low rangeOfString:@"sms"].location == NSNotFound &&
            [low rangeOfString:@"oauth"].location == NSNotFound) return nil;

        // ★ 精确区分：发验证码 vs 短信登录
        // ★ 精确区分（上一版写得太宽，把密码登录 /api/oauth2/login 也当成
        //   短信登录，给它加了 device_name/from_pv 等字段 → 参数污染 → 登录失败）
        // ★★ 密码登录（/api/oauth2/*）**完全透传**：
        //   App 用 getKey 拿到的 RSA 公钥加密密码，而该密钥与它自己的 appkey 绑定；
        //   我们把 appkey 换成 HD 版 + 加上 android 参数 → 服务端解不开 → 登录失败。
        //   所以这类请求不动它。
        if ([low rangeOfString:@"oauth2/"].location != NSNotFound) {
            BRINFO(@"[登录] oauth2 请求原样透传: %@", path);
            return nil;
        }
        BOOL isSmsSend  = ([low rangeOfString:@"/sms/send"].location != NSNotFound);
        //   只有完整子路径 /login/sms 才算短信登录
        BOOL isSmsLogin = ([low rangeOfString:@"/login/sms"].location != NSNotFound);
        //   密码登录（/api/oauth2/login 等）：只补公共字段，不加短信专属字段
        BOOL isPwdLogin = (([low rangeOfString:@"oauth2/login"].location != NSNotFound) ||
                           ([low rangeOfString:@"/login"].location != NSNotFound)) &&
                          (!isSmsSend && !isSmsLogin);

        NSMutableDictionary *kv = [NSMutableDictionary dictionary];
        NSMutableArray *order = [NSMutableArray array];
        for (NSArray *pr in BRQueryPairs(query)) {
            NSString *k = pr[0], *v = BRURLDecode(pr[1]);
            if (![kv objectForKey:k]) [order addObject:k];
            [kv setObject:v forKey:k];
        }

        void (^setIfEmpty)(NSString *, NSString *) = ^(NSString *k, NSString *v) {
            if (![kv objectForKey:k] || ![[kv objectForKey:k] length]) {
                if (![kv objectForKey:k]) [order addObject:k];
                [kv setObject:v forKey:k];
            }
        };

        // ---- 公共字段 ----
        setIfEmpty(@"build", BR_LOGIN_BUILD);
        setIfEmpty(@"c_locale", @"zh_CN");
        setIfEmpty(@"s_locale", @"zh_CN");
        setIfEmpty(@"channel", @"master");
        setIfEmpty(@"cid", @"86");
        setIfEmpty(@"disable_rcmd", @"0");
        setIfEmpty(@"mobi_app", @"android_hd");
        setIfEmpty(@"platform", @"android");
        setIfEmpty(@"statistics", BR_LOGIN_STATS);

        if ([buvid length]) {
            setIfEmpty(@"buvid", buvid);
            setIfEmpty(@"local_id", buvid);
            setIfEmpty(@"bili_local_id", buvid);
            setIfEmpty(@"device_id", buvid);
        }

        // ---- 发验证码专属 ----
        if (isSmsSend && [buvid length]) {
            long long ms = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
            NSString *seed = [NSString stringWithFormat:@"%@%lld", buvid, ms];
            NSData *sd = [seed dataUsingEncoding:NSUTF8StringEncoding];
            unsigned char dg[16];
            if (BRCC_MD5(sd.bytes, (unsigned int)sd.length, dg) != NULL) {
                NSMutableString *h = [NSMutableString string];
                for (int i = 0; i < 16; i++) [h appendFormat:@"%02x", dg[i]];
                setIfEmpty(@"login_session_id", h);
                BRINFO(@"[登录] 发验证码已补 login_session_id");
            }
        }

        // ---- 短信登录专属 ----
        if (isSmsLogin) {
            setIfEmpty(@"device", @"phone");
            setIfEmpty(@"device_name", @"vivo");
            setIfEmpty(@"device_platform", @"Android14vivo");
            setIfEmpty(@"from_pv", @"main.my-information.my-login.0.click");
            BRINFO(@"[登录] 短信登录已补 device/from_pv");
        }

        if (isPwdLogin) BRINFO(@"[登录] 密码登录请求（只补公共字段）");
        // ---- 重签：去掉 appkey/sign，追加有效 appkey，按 key 排序 ----
        NSMutableArray *keys = [NSMutableArray array];
        for (NSString *k in order)
            if (![k isEqualToString:@"appkey"] && ![k isEqualToString:@"sign"])
                [keys addObject:k];
        [keys addObject:@"appkey"];
        [keys sortUsingSelector:@selector(compare:)];

        NSMutableArray *rawPairs = [NSMutableArray array];
        NSMutableArray *outPairs = [NSMutableArray array];
        for (NSString *k in keys) {
            NSString *v = [k isEqualToString:@"appkey"] ? BR_LOGIN_APPKEY : [kv objectForKey:k];
            if (v == nil) v = @"";
            [rawPairs addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
            [outPairs addObject:[NSString stringWithFormat:@"%@=%@",
                                 k, [v stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: v]];
        }
        NSString *raw = [rawPairs componentsJoinedByString:@"&"];
        NSString *signSeed = [raw stringByAppendingString:BR_LOGIN_APPSEC];
        NSData *sd2 = [signSeed dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char dg2[16];
        if (BRCC_MD5(sd2.bytes, (unsigned int)sd2.length, dg2) == NULL) return nil;
        NSMutableString *sign = [NSMutableString string];
        for (int i = 0; i < 16; i++) [sign appendFormat:@"%02x", dg2[i]];
        [outPairs addObject:[NSString stringWithFormat:@"sign=%@", sign]];

        BRINFO(@"[登录] 已补齐并重签 %@（%@）", path, isSmsSend ? @"发验证码" : (isSmsLogin ? @"短信登录" : @"其他"));
        return [outPairs componentsJoinedByString:@"&"];
    } @catch (NSException *e) {
        BRERR(@"[登录] 处理异常: %@", [e description]);
        return nil;
    }
}

static NSURLRequest *BRRewriteRequestEx(NSURLRequest *req, BRRoute **outRoute) {
    if (outRoute) *outRoute = nil;
    BRLockInit();
    [gBRRewriteLock lock];
    @try {
        if (req == nil) { BRDIAG(@"改写: req 为 nil"); [gBRRewriteLock unlock]; return req; }
        NSString *host = [[req URL] host];
        NSString *path = [[req URL] path];
        BRDIAG(@"改写: 进入 host=%@ path=%@", host, path);
        if (!BRIsBiliHost(host)) { BRDIAG(@"改写: host 不在名单"); [gBRRewriteLock unlock]; return req; }

        // ★ 登录/验证码请求：补齐新接口要求的参数并重签
        @try {
            NSString *low = [path lowercaseString];
            if ([low rangeOfString:@"login"].location != NSNotFound ||
                [low rangeOfString:@"sms"].location != NSNotFound ||
                [low rangeOfString:@"oauth"].location != NSNotFound) {
                // ★★★ 密码登录 -> 短信登录 翻译
        //   用户要求：手机号/账户框填手机号、密码框填验证码。
        //   老接口 /api/oauth2/login 已关停，这里把它的 username/password
        //   取出来当作 mobile/code，改道到 x/passport-login/login/sms。
        if ([low rangeOfString:@"/oauth2/login"].location != NSNotFound) {
            // 这里没有 qs，自己解一下原请求的 query
            NSMutableDictionary *lqs = [NSMutableDictionary dictionary];
            for (NSString *kv in [[[req URL] query] ?: @"" componentsSeparatedByString:@"&"]) {
                NSRange eq = [kv rangeOfString:@"="];
                if (eq.location == NSNotFound) continue;
                NSString *k = [kv substringToIndex:eq.location];
                NSString *v = [kv substringFromIndex:eq.location + 1];
                NSString *dv = [v stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                if (k && [k length]) [lqs setObject:(dv ?: v) forKey:k];
            }
            NSString *mobile = lqs[@"username"] ?: lqs[@"mobile"] ?: @"";
            NSString *code   = lqs[@"password"] ?: lqs[@"code"] ?: @"";
            if ([mobile length] && [code length]) {
                NSMutableDictionary *lp = [NSMutableDictionary dictionary];
                [lp setObject:mobile forKey:@"mobile"];
                [lp setObject:code forKey:@"code"];
                [lp setObject:@"86" forKey:@"country_code"];
                [lp setObject:@"2001100" forKey:@"build"];
                [lp setObject:@"android_hd" forKey:@"mobi_app"];
                [lp setObject:@"android" forKey:@"platform"];
                [lp setObject:@"master" forKey:@"channel"];
                [lp setObject:@"zh_CN" forKey:@"c_locale"];
                [lp setObject:@"zh_CN" forKey:@"s_locale"];
                [lp setObject:@"{\"appId\":5,\"platform\":3,\"version\":\"2.0.1\",\"abtest\":\"\"}" forKey:@"statistics"];
                NSString *bv = [BRSession buvid3];
                if ([bv length]) {
                    [lp setObject:bv forKey:@"buvid"];
                    [lp setObject:bv forKey:@"local_id"];
                    [lp setObject:bv forKey:@"bili_local_id"];
                    [lp setObject:bv forKey:@"device_id"];
                }
                NSString *lq = BRBuildSignedQuery(lp);
                NSURL *lu = [NSURL URLWithString:[NSString stringWithFormat:
                    @"https://passport.bilibili.com/x/passport-login/login/sms?%@", lq]];
                if (lu) {
                    NSMutableURLRequest *lm = [req mutableCopy];
                    [lm setURL:lu];
                    BRINFO(@"[登录] 密码登录已翻译为短信登录: %@", mobile);
                    [gBRRewriteLock unlock];
                    return lm;
                }
            }
            BRINFO(@"[登录] oauth2/login 缺手机号或验证码，透传");
            return nil;
        }
        NSString *nq = BREnhanceLoginQuery(path, [[req URL] query], [BRSession buvid3]);
                if ([nq length]) {
                    NSString *base = [NSString stringWithFormat:@"%@://%@%@",
                                      [[req URL] scheme], host, path];
                    NSURL *nu = [NSURL URLWithString:[base stringByAppendingFormat:@"?%@", nq]];
                    if (nu) {
                        NSMutableURLRequest *nm = [req mutableCopy];
                        [nm setURL:nu];
                        [gBRRewriteLock unlock];
                        return nm;
                    }
                }
            }
        } @catch (NSException *e) { BRERR(@"[登录] 包装异常: %@", [e description]); }

        BRRoute *route = [BRRouter routeForRequest:req];
        BRDIAG(@"改写: 路由结果 kind=%@ url=%@ note=%@",
               route.kind, route.url ? @"有" : @"nil", route.note);
        if (outRoute) *outRoute = route;
        if (route == nil || route.url == nil) { BRDIAG(@"改写: 无路由或无上游地址"); [gBRRewriteLock unlock]; return req; }

        if (route.drop) {
            BRDBG(@"[改写] 丢弃 %@（%@）", [[req URL] path], route.note);
            [gBRRewriteLock unlock];
        return req;   // 丢弃逻辑这一版先不动，避免行为突变
        }

        NSMutableURLRequest *m = [req mutableCopy];
        if (m == nil) { [gBRRewriteLock unlock]; return req; }

        if ([route.url isEqualToString:[[req URL] absoluteString]]) {
            BRDIAG(@"改写: 上游地址与原地址相同，无需改");
        }
        if (![route.url isEqualToString:[[req URL] absoluteString]]) {
            NSURL *u = [NSURL URLWithString:route.url];
            if (u == nil) { [gBRRewriteLock unlock]; return req; }
            [m setURL:u];
            NSString *shown = route.url.length > 120
                ? [[route.url substringToIndex:120] stringByAppendingString:@"…"]
                : route.url;
            BRINFO(@"[改写] %@ -> %@", [[req URL] path], shown);
        }

        // UA（搜索要浏览器 UA、登录要 BiliDroid）
        NSDictionary *h = [BRSession headersForUA:route.ua];
        for (NSString *k in h) [m setValue:[h objectForKey:k] forHTTPHeaderField:k];

        if (route.extraHeaders != nil) {
            for (NSString *k in route.extraHeaders)
                [m setValue:[route.extraHeaders objectForKey:k] forHTTPHeaderField:k];
        }

        // Cookie（匿名接口一个都不带）
        if (!route.anonymous) {
            NSString *ck = [BRSession cookie];
            if (route.extraCookie.length) {
                ck = ck.length ? [NSString stringWithFormat:@"%@; %@", route.extraCookie, ck]
                               : route.extraCookie;
            }
            if (ck.length) [m setValue:ck forHTTPHeaderField:@"Cookie"];
        } else {
            [m setValue:nil forHTTPHeaderField:@"Cookie"];
        }

        [gBRRewriteLock unlock];

        return m;
    } @catch (NSException *e) {
        BRERR(@"[改写] 异常: %@", [e description]);
        [gBRRewriteLock unlock];
        return req;
    }
}

// 兼容旧调用点
static NSURLRequest *BRRewriteRequest(NSURLRequest *req) {
    return BRRewriteRequestEx(req, NULL);
}


static NSData *(*o_sendSync)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **);
static NSData *h_sendSync(id self, SEL _cmd, NSURLRequest *req,
                          NSURLResponse **respOut, NSError **errOut) {
    @try {
        if (BRLogEnabled()) {
            NSString *host = [[req URL] host];
            if (BRIsBiliHost(host)) BRDBG(@"[同步] %@", [[req URL] path]);
        }
    } @catch (NSException *e) { }
    BRRoute *brRoute = nil;
    NSURLRequest *brq = BRRewriteRequestEx(req, &brRoute);

    NSData *brData = o_sendSync(self, _cmd, brq, respOut, errOut);

    // ★ 同步路径也要做响应改写 —— 之前漏了这一步，
    //   导致「请求去了新接口、新结构却原样交给老客户端」（arrayValue 拿到字典返回 nil）
    @try {
        if (brData != nil && brRoute != nil && brRoute.kind != nil) {
            NSUInteger before = [brData length];
            NSData *conv = [BRRouter convertResponse:brData forRoute:brRoute];
            if (conv != nil) {
                BRINFO(@"[改写] 同步响应 %@：%lu -> %lu 字节",
                       brRoute.kind, (unsigned long)before, (unsigned long)[conv length]);
                brData = conv;

                // ★★★ 关键：必须同步更新 respOut 里的 Content-Length！
                //   客户端会按 NSURLResponse 声明的长度去读/校验响应体，
                //   我们换了 body 却不改长度 → 长度不匹配 → JSON 解析失败
                //   → arrayValue 拿到 nil → 整页空白（这正是"转换器一开就白页"的原因）。
                //   参考实现是独立 HTTP 代理，它重新封装响应所以长度天然正确；
                //   进程内替换必须自己补这一步。
                if (respOut != NULL && *respOut != nil) {
                    Class respCls = NSClassFromString(@"NSHTTPURLResponse");
                    id old = *respOut;
                    if (respCls != Nil && [old isKindOfClass:respCls]) {
                        NSHTTPURLResponse *o = (NSHTTPURLResponse *)old;
                        NSMutableDictionary *hd = [[o allHeaderFields] mutableCopy];
                        if (hd == nil) hd = [NSMutableDictionary dictionary];
                        [hd setObject:[NSString stringWithFormat:@"%lu", (unsigned long)[conv length]]
                               forKey:@"Content-Length"];
                        [hd setObject:@"application/json" forKey:@"Content-Type"];
                        id nr = [[respCls alloc] initWithURL:[o URL]
                                                  statusCode:[o statusCode]
                                                 HTTPVersion:@"HTTP/1.1"
                                                headerFields:hd];
                        if (nr != nil) {
                            *respOut = nr;
                            BRDBG(@"[改写] respOut 已更新 Content-Length=%lu",
                                  (unsigned long)[conv length]);
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        BRERR(@"[改写] 同步响应转换异常: %@", [e description]);
    }

    return brData;
}

static void (*o_sendAsync)(id, SEL, NSURLRequest *, NSOperationQueue *,
                           void (^)(NSURLResponse *, NSData *, NSError *));
static void h_sendAsync(id self, SEL _cmd, NSURLRequest *req, NSOperationQueue *q,
                        void (^h)(NSURLResponse *, NSData *, NSError *)) {
    @try {
        if (BRLogEnabled()) {
            NSString *host = [[req URL] host];
            if (BRIsBiliHost(host)) BRDBG(@"[异步] %@", [[req URL] path]);
        }
    } @catch (NSException *e) { }
    o_sendAsync(self, _cmd, req, q, h);
}

static id (*o_initWithRequest)(id, SEL, NSURLRequest *, id);
static id h_initWithRequest(id self, SEL _cmd, NSURLRequest *req, id delegate) {
    @try {
        if (BRLogEnabled()) {
            NSString *host = [[req URL] host];
            if (BRIsBiliHost(host)) BRDBG(@"[连接] %@", [[req URL] path]);
        }
    } @catch (NSException *e) { }
    NSURLRequest *brq = BRRewriteRequest(req);

    return o_initWithRequest(self, _cmd, brq, delegate);
}

static id (*o_initWithRequestStart)(id, SEL, NSURLRequest *, id, BOOL);
static id h_initWithRequestStart(id self, SEL _cmd, NSURLRequest *req, id delegate,
                                 BOOL startNow) {
    @try {
        if (BRLogEnabled()) {
            NSString *host = [[req URL] host];
            if (BRIsBiliHost(host)) BRDBG(@"[连接+] %@", [[req URL] path]);
        }
    } @catch (NSException *e) { }
    NSURLRequest *brq = BRRewriteRequest(req);

    // ★ 需要改写响应时，把 delegate 换成代理
    id brd = delegate;
    @try {
        if (delegate != nil) {
            BRRoute *r = [BRRouter routeForRequest:req];
            if (r != nil && r.kind != nil) {
                BRDelegateProxy *px = [[BRDelegateProxy alloc] init];
                px.real = delegate;
                px.route = r;
                brd = px;
                BRHoldProxy(px);   // ★ 必须强持有，否则会被提前释放
                BRINFO(@"[改写] 已挂响应代理（%@）", r.kind);
            }
        }
    } @catch (NSException *e) { brd = delegate; }

    return o_initWithRequestStart(self, _cmd, brq, brd, startNow);
}

#pragma mark - 装载

// 每一步单独 try，绝不因为某一步失败而让整个初始化抛出

#pragma mark - ★★★ NSURLSession 挂钩（App 大量使用，之前完全没覆盖）

static id (*o_dataTaskReq)(id, SEL, NSURLRequest *);
static id (*o_dataTaskReqCH)(id, SEL, NSURLRequest *,
                             void (^)(NSData *, NSURLResponse *, NSError *));
static id (*o_dataTaskURL)(id, SEL, NSURL *);
static id (*o_dataTaskURLCH)(id, SEL, NSURL *,
                             void (^)(NSData *, NSURLResponse *, NSError *));

// block 版：改写请求 + 包一层响应转换
static id h_dataTaskReqCH(id self, SEL _cmd, NSURLRequest *req,
                          void (^h)(NSData *, NSURLResponse *, NSError *)) {
    @try {
        if (req == nil || h == nil) {
            if (h == nil) return o_dataTaskReqCH(self, _cmd, req, h);
        }
        BRRoute *route = nil;
        NSURLRequest *brq = BRRewriteRequestEx(req, &route);
        if (route == nil || route.kind == nil || h == nil) {
            return o_dataTaskReqCH(self, _cmd, brq, h);
        }
        NSString *kind = [route.kind copy];
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *d, NSURLResponse *r, NSError *e) {
                NSData *out = d;
                @try {
                    if (d != nil && kind != nil) {
                        BRRoute *rr = [[BRRoute alloc] init];
                        rr.kind = kind;
                        NSData *c = [BRRouter convertResponse:d forRoute:rr];
                        if (c != nil) out = c;
                    }
                } @catch (NSException *ex) { }
                h(out, r, e);
            };
        return o_dataTaskReqCH(self, _cmd, brq, wrapped);
    } @catch (NSException *e) {
        BRERR(@"[NSURLSession] dataTask(CH) 异常: %@", [e description]);
    }
    return o_dataTaskReqCH(self, _cmd, req, h);
}

// delegate 版：只改写请求（响应由 session 的 delegate 收，无法在此包）
static id h_dataTaskReq(id self, SEL _cmd, NSURLRequest *req) {
    @try {
        NSURLRequest *brq = BRRewriteRequest(req);
        return o_dataTaskReq(self, _cmd, brq);
    } @catch (NSException *e) {
        BRERR(@"[NSURLSession] dataTask 异常: %@", [e description]);
    }
    return o_dataTaskReq(self, _cmd, req);
}

static id h_dataTaskURLCH(id self, SEL _cmd, NSURL *u,
                          void (^h)(NSData *, NSURLResponse *, NSError *)) {
    @try {
        if (u == nil) return o_dataTaskURLCH(self, _cmd, u, h);
        NSString *host = [u host];
        if (!BRIsBiliHost(host)) return o_dataTaskURLCH(self, _cmd, u, h);
        Class reqCls = NSClassFromString(@"NSURLRequest");
        if (reqCls == Nil) return o_dataTaskURLCH(self, _cmd, u, h);
        NSURLRequest *req = [reqCls requestWithURL:u];
        return h_dataTaskReqCH(self, _cmd, req, h);
    } @catch (NSException *e) { }
    return o_dataTaskURLCH(self, _cmd, u, h);
}

static id h_dataTaskURL(id self, SEL _cmd, NSURL *u) {
    @try {
        if (u == nil) return o_dataTaskURL(self, _cmd, u);
        NSURLRequest *req = [NSClassFromString(@"NSURLRequest") requestWithURL:u];
        if (req != nil) return h_dataTaskReq(self, _cmd, req);
    } @catch (NSException *e) { }
    return o_dataTaskURL(self, _cmd, u);
}

#pragma mark - ★ 登录页改造（短信验证码登录）

// ★★★ 四条从实测崩溃中得出的铁律：
//   ① 绝不 hook「继承来的方法」。BBPhoneUserLoginViewController 自己不实现
//      viewDidAppear:（继承自父类），对它做 MSHookMessageEx 会破坏消息转发链，
//      表现为「进入登录页 3 秒后崩溃」。正确做法是 hook 真正的实现者
//      （UIViewController），再按类名过滤。
//   ② 绝不在 viewDidLayoutSubviews 里干活（QuartzCore 布局周期内 → 绑定失败）
//   ③ 绝不用 dispatch_after / dispatch_async（libdispatch 符号绑定失败 → SIGTRAP）
//      一律用 performSelector:withObject:afterDelay:
//   ④ 用 performSelector 前必须确保 selector 存在（否则 unrecognized selector）

static void br_relabel_now(id self, SEL _cmd) {
    @try { BRRelabelLoginPage(self); } @catch (NSException *e) { }
}

// 是否是我们关心的登录/注册页
static BOOL BRIsLoginVC(id vc) {
    @try {
        NSString *cn = NSStringFromClass([vc class]);
        if (cn == nil) return NO;
        if ([cn rangeOfString:@"Login"].location == NSNotFound &&
            [cn rangeOfString:@"Register"].location == NSNotFound) return NO;
        // 只认哔哩哔哩自己的类
        return ([cn rangeOfString:@"BB"].location == 0 ||
                [cn rangeOfString:@"Bili"].location == 0);
    } @catch (NSException *e) { return NO; }
}

static void (*o_vcDidAppear)(id, SEL, BOOL);
static void h_vcDidAppear(id self, SEL _cmd, BOOL a) {
    if (o_vcDidAppear != NULL) o_vcDidAppear(self, _cmd, a);
    @try {
        if (!BRIsLoginVC(self)) return;
        Class c = [self class];
        if (![c instancesRespondToSelector:@selector(brRelabelNow)]) {
            class_addMethod(c, @selector(brRelabelNow), (IMP)&br_relabel_now, "v@:");
        }
        [self performSelector:@selector(brRelabelNow) withObject:nil afterDelay:0.35];
        [self performSelector:@selector(brRelabelNow) withObject:nil afterDelay:1.20];
        [self performSelector:@selector(brRelabelNow) withObject:nil afterDelay:2.50];
        BRINFO(@"[登录] 已安排改造: %@", NSStringFromClass(c));
    } @catch (NSException *e) { }
}

static void br_hook_login_vcs(void) {
    Class vcCls = NSClassFromString(@"UIViewController");
    if (vcCls == Nil) { BRINFO(@"★ 拿不到 UIViewController"); return; }
    MSHookMessageEx(vcCls, @selector(viewDidAppear:),
                    (IMP)&h_vcDidAppear, (IMP *)&o_vcDidAppear);
    BRINFO(@"已挂 UIViewController.viewDidAppear:（按类名过滤登录页）");
}

%ctor
{
    @autoreleasepool {
        NSString *bid = nil;
        @try { bid = [[NSBundle mainBundle] bundleIdentifier]; } @catch (NSException *e) { }
        NSString *mark = [NSString stringWithFormat:@"ctor 进入 (bid=%@)", bid ?: @"?"];
        BRMark([mark UTF8String]);

        // ① 日志系统
        @try {
            BRLogInit();
            BRMark("01 BRLogInit 完成");
        } @catch (NSException *e) { BRMark("01 BRLogInit 抛异常"); }

        @try {
            BRINFO(@"===== BiloginalfX7 Alpha6.1 已加载 (bid=%@) =====", bid);
        } @catch (NSException *e) { }

        // ② ID 映射（原来是 +load，现在显式调用）
        @try {
            [BRStore bootstrap];
            BRMark("02 BRStore bootstrap 完成");
        } @catch (NSException *e) { BRMark("02 BRStore bootstrap 抛异常"); }

        // ③ 会话初始化与预热
        @try {
            [BRSession bootstrap];
            BRMark("03 BRSession bootstrap 完成");
        } @catch (NSException *e) { BRMark("03 BRSession bootstrap 抛异常"); }

        @try {
            [BRSession warmUp];
            BRMark("04 BRSession warmUp 完成");
        } @catch (NSException *e) { BRMark("04 BRSession warmUp 抛异常"); }

        // ④ 注册 NSURLProtocol
        @try {
            Class protoCls = Nil;   // ★ Alpha9.1：NSURLProtocol 层暂时关闭（运行时建类会导致 App 崩溃）
            if (protoCls != Nil) {
                Class protoBase = NSClassFromString(@"NSURLProtocol");   // ★ 运行时取类，避免符号引用
                if (protoBase != Nil) [protoBase registerClass:protoCls];
                BRMark("05 BRURLProtocol 已注册");
                BRINFO(@"已注册 BRURLProtocol");
            } else {
                BRMark("05 BRURLProtocol 类不存在");
            }
        } @catch (NSException *e) {
            BRMark("05 registerClass 抛异常");
        }

        // ⑤ 兜底 hook
        @try {
            Class conn = objc_getClass("NSURLConnection");
            if (conn != Nil) {
                MSHookMessageEx(object_getClass(conn),
                    @selector(sendSynchronousRequest:returningResponse:error:),
                    (IMP)&h_sendSync, (IMP *)&o_sendSync);
                MSHookMessageEx(object_getClass(conn),
                    @selector(sendAsynchronousRequest:queue:completionHandler:),
                    (IMP)&h_sendAsync, (IMP *)&o_sendAsync);
                MSHookMessageEx(conn, @selector(initWithRequest:delegate:),
                    (IMP)&h_initWithRequest, (IMP *)&o_initWithRequest);
                MSHookMessageEx(conn, @selector(initWithRequest:delegate:startImmediately:),
                    (IMP)&h_initWithRequestStart, (IMP *)&o_initWithRequestStart);
                BRMark("06 NSURLConnection 4 个入口已挂载");
                BRINFO(@"NSURLConnection 已挂载");
                // ★★★ NSURLSession 挂钩（App 大量使用；之前完全没覆盖）
                Class sessCls = NSClassFromString(@"NSURLSession");
                if (sessCls != Nil) {
                    MSHookMessageEx(sessCls, @selector(dataTaskWithRequest:),
                        (IMP)&h_dataTaskReq, (IMP *)&o_dataTaskReq);
                    MSHookMessageEx(sessCls, @selector(dataTaskWithRequest:completionHandler:),
                        (IMP)&h_dataTaskReqCH, (IMP *)&o_dataTaskReqCH);
                    MSHookMessageEx(sessCls, @selector(dataTaskWithURL:),
                        (IMP)&h_dataTaskURL, (IMP *)&o_dataTaskURL);
                    MSHookMessageEx(sessCls, @selector(dataTaskWithURL:completionHandler:),
                        (IMP)&h_dataTaskURLCH, (IMP *)&o_dataTaskURLCH);
                    BRINFO(@"NSURLSession 已挂载");
                // ★ 登录页改造：hook 登录页与「我的」页
                // ★ 只挂 iPhone 那一个类！
                //   之前循环挂 3 个类，而 o_loginVCDidAppear / o_loginVCLayout
                //   是**全局变量**，每挂一次就被覆盖 → 第一个类的 hook
                //   会去调第三个类的原函数 → 调错方法 → 崩溃。
                br_hook_login_vcs();
                // 「我的」页 hook 暂停：类名尚未找到，且同样有全局指针风险
                } else {
                    BRINFO(@"找不到 NSURLSession");
                }
            } else {
                BRMark("06 找不到 NSURLConnection");
            }
        } @catch (NSException *e) {
            BRMark("06 MSHookMessageEx 抛异常");
        }

        BRMark("07 初始化全部完成");
        @try { BRINFO(@"初始化完成"); } @catch (NSException *e) { }
        BRRunSelfTest();   // 自检
    }
}
