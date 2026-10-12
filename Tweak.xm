//
//  Tweak.xm —— BiloginalfX7
//
//  哔哩哔哩 4.34（iOS 7+，iPhone / iPad 通用）复活插件
//
//  ============================ 架构 ============================
//  对 bili-universal（armv7 切片，符号表未 strip：193,296 个符号 /
//  106,838 个方法名 / 6,012 个类）做静态分析后确认的网络栈：
//
//      业务 API（535 个 BB*Api / BiliApiV2Base / BiliApiV3Base）
//          ↓  addToQueueSync / addToQueueAsync
//      BiliApiV2Queue（NSOperationQueue）
//          ↓
//      APURLConnectionOperation（B 站 fork 的 AFNetworking 1.x）
//          ↓
//      -[NSURLConnection initWithRequest:delegate:]        ← 主路径
//          ↓
//      BiliURLProtocol（App 自己 +installProtocol 注册的 NSURLProtocol 子类）
//          ↓
//      它内部的 NSURLSession 发出真实请求
//
//  也就是说 **App 本身就跑在 NSURLProtocol 这一层**。
//  所以这里注册一个同类协议 —— 后注册的优先匹配 —— 一次性拦住所有请求，
//  不管上层用同步、异步还是 delegate 方式发起。
//
//  另外还挂了 NSURLConnection 的四个入口作兜底（覆盖少数不走 URL 加载系统的路径）。
//  ==============================================================
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRURLProtocol.h"

#pragma mark - 兜底 hook：NSURLConnection 四个入口

static NSData *(*o_sendSync)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **);
static NSData *h_sendSync(id self, SEL _cmd, NSURLRequest *req,
                          NSURLResponse **respOut, NSError **errOut) {
    // 请求仍会经过 URL 加载系统，BRURLProtocol 会接管并改写。
    // 这里只是把调用链记录下来，便于排查哪些接口走的是同步路径。
    @autoreleasepool {
        if (BRLogEnabled()) {
            NSString *host = [[req URL] host];
            if (BRIsBiliHost(host)) BRDBG(@"[同步] %@", [[req URL] path]);
        }
    }
    return o_sendSync(self, _cmd, req, respOut, errOut);
}

static void (*o_sendAsync)(id, SEL, NSURLRequest *, NSOperationQueue *,
                           void (^)(NSURLResponse *, NSData *, NSError *));
static void h_sendAsync(id self, SEL _cmd, NSURLRequest *req, NSOperationQueue *q,
                        void (^h)(NSURLResponse *, NSData *, NSError *)) {
    @autoreleasepool {
        if (BRLogEnabled()) {
            NSString *host = [[req URL] host];
            if (BRIsBiliHost(host)) BRDBG(@"[异步] %@", [[req URL] path]);
        }
    }
    o_sendAsync(self, _cmd, req, q, h);
}

static id (*o_initWithRequest)(id, SEL, NSURLRequest *, id);
static id h_initWithRequest(id self, SEL _cmd, NSURLRequest *req, id delegate) {
    // ★ 这是主路径（AFNetworking fork 全部走这里）
    @autoreleasepool {
        if (BRLogEnabled()) {
            NSString *host = [[req URL] host];
            if (BRIsBiliHost(host)) BRDBG(@"[连接] %@", [[req URL] path]);
        }
    }
    return o_initWithRequest(self, _cmd, req, delegate);
}

static id (*o_initWithRequestStart)(id, SEL, NSURLRequest *, id, BOOL);
static id h_initWithRequestStart(id self, SEL _cmd, NSURLRequest *req, id delegate,
                                 BOOL startNow) {
    @autoreleasepool {
        if (BRLogEnabled()) {
            NSString *host = [[req URL] host];
            if (BRIsBiliHost(host)) BRDBG(@"[连接+] %@", [[req URL] path]);
        }
    }
    return o_initWithRequestStart(self, _cmd, req, delegate, startNow);
}

#pragma mark - 装载

%ctor
{
    @autoreleasepool {
        BRLogInit();
        BRINFO(@"===== BiloginalfX7 已加载 =====");

        // 1) ID 映射必须最先加载 —— 路由与响应改写都要用
        [BRStore load];

        // 2) 异步预热会话（buvid3/buvid4 + wbi 密钥），不阻塞启动
        [BRSession warmUp];

        // 3) ★ 注册自己的 NSURLProtocol
        //    NSURLProtocol 的匹配顺序是「最后注册的最先询问」，
        //    这里注册后我们会先于 App 的 BiliURLProtocol 拿到请求。
        [NSURLProtocol registerClass:[BRURLProtocol class]];
        BRINFO(@"已注册 BRURLProtocol");

        // 4) 兜底 hook（NSURLConnection 四个入口）
        Class conn = objc_getClass("NSURLConnection");
        if (conn != nil) {
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
            BRINFO(@"NSURLConnection 已挂载（4 个入口）");
        } else {
            BRERR(@"找不到 NSURLConnection");
        }

        BRINFO(@"初始化完成");
    }
}
