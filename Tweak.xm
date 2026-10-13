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
//       改成 %ctor 里显式调用 +bootstrap
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

static NSURLRequest *BRRewriteRequest(NSURLRequest *req) {
    @try {
        if (req == nil) return req;
        NSString *host = [[req URL] host];
        if (!BRIsBiliHost(host)) return req;

        BRRoute *route = [BRRouter routeForRequest:req];
        if (route == nil || route.url == nil) return req;

        if (route.drop) {
            BRDBG(@"[改写] 丢弃 %@（%@）", [[req URL] path], route.note);
            return req;   // 丢弃逻辑这一版先不动，避免行为突变
        }

        NSMutableURLRequest *m = [req mutableCopy];
        if (m == nil) return req;

        if (![route.url isEqualToString:[[req URL] absoluteString]]) {
            NSURL *u = [NSURL URLWithString:route.url];
            if (u == nil) return req;
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

        return m;
    } @catch (NSException *e) {
        BRERR(@"[改写] 异常: %@", [e description]);
        return req;
    }
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
    return o_sendSync(self, _cmd, req, respOut, errOut);
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
                MSHookMessageEx(conn,
                    @selector(sendSynchronousRequest:returningResponse:error:),
                    (IMP)&h_sendSync, (IMP *)&o_sendSync);
                MSHookMessageEx(conn,
                    @selector(sendAsynchronousRequest:queue:completionHandler:),
                    (IMP)&h_sendAsync, (IMP *)&o_sendAsync);
                MSHookMessageEx(conn, @selector(initWithRequest:delegate:),
                    (IMP)&h_initWithRequest, (IMP *)&o_initWithRequest);
                MSHookMessageEx(conn, @selector(initWithRequest:delegate:startImmediately:),
                    (IMP)&h_initWithRequestStart, (IMP *)&o_initWithRequestStart);
                BRMark("06 NSURLConnection 4 个入口已挂载");
                BRINFO(@"NSURLConnection 已挂载");
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
