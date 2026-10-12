//
//  BRURLProtocol.h —— 拦截层
//
//  为什么用 NSURLProtocol 而不是 hook NSURLConnection：
//  静态分析确认 4.34 的网络栈是
//      业务 API → BiliApiV2/V3 → APURLConnectionOperation(AFNetworking fork)
//                → -[NSURLConnection initWithRequest:delegate:]
//                → BiliURLProtocol（App 自己注册的 NSURLProtocol）
//  也就是说 **App 本身就跑在 NSURLProtocol 这一层**。
//  我们注册一个同类协议（后注册的优先），就能一次性拦住所有请求 ——
//  不管上层用同步、异步还是 delegate 方式发起。
//
//  ⚠️ 对我们自己发出的请求必须打标记，否则会无限递归。
//

#import <Foundation/Foundation.h>

@interface BRURLProtocol : NSURLProtocol
@end

// 内部请求标记（放在 NSURLProtocol 的 request property 里，不会随网络发出）
extern NSString *const kBRInternalKey;

// 判断某个 host 是否属于需要接管的 B 站域名
BOOL BRIsBiliHost(NSString *host);
