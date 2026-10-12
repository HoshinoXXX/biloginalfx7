//
//  BRSession.h —— 会话状态：buvid / Cookie / 签名 / 风控请求头
//
//  这里是插件「不被风控挡住」的全部依据：
//   1) 完整浏览器指纹（UA + Sec-Ch-Ua 系列必须成套）
//   2) buvid3 + buvid4（只带 buvid3 会 -352）
//   3) b_nut（首次进站时间，风控连同 buvid 一起看）
//   4) wbi 签名（RFC3986）与 APP 签名（Java URLEncoder）——两套编码绝不能混用
//

#import <Foundation/Foundation.h>

@interface BRSession : NSObject

+ (void)bootstrap;  // ★ 同 BRStore：不用 +load，避免 dyld 初始化期抛异常
+ (void)warmUp;          // 异步预热 buvid / wbi 密钥

// ---- 身份 ----
+ (NSString *)buvid3;
+ (NSString *)buvid4;
+ (NSString *)bNut;
+ (NSString *)cookie;              // 拼好的完整 Cookie 串
+ (void)setUserCookie:(NSString *)c;
+ (BOOL)hasUserCookie;

// ---- 风控请求头 ----
// 默认返回「完整 Chrome 指纹」；若调用方显式传了 User-Agent，
// 则**不再附带 Chrome 的 Sec-Ch-Ua**（混搭指纹比不设更糟）。
+ (NSDictionary *)headersForUA:(NSString *)ua;

+ (NSString *)appUA;               // BiliApp/434
+ (NSString *)searchUA;            // 浏览器 UA（搜索接口必须用这个）
+ (NSString *)loginUA;             // BiliDroid（登录接口）
+ (NSString *)chromeUA;

// ---- 签名 ----
+ (NSString *)md5:(NSString *)s;
// wbi：RFC3986 编码（空格 %20）
+ (NSString *)wbiSignURL:(NSString *)url;
// APP 签名：Java URLEncoder 语义（空格 +）
+ (NSString *)javaURLEncode:(NSString *)s;
+ (NSString *)appSignWithParams:(NSDictionary *)params
                         appkey:(NSString *)appkey
                         appsec:(NSString *)appsec;

// ---- 限流 ----
// 上游请求串行 + 最小间隔（避免被判异常流量）
+ (void)throttle;

@end
