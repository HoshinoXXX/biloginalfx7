//
//  BRLogin.h —— 短信验证码登录（改造现有登录页）
//

#import <Foundation/Foundation.h>

@interface BRLogin : NSObject
+ (void)sendSmsToPhone:(NSString *)phone completion:(void (^)(BOOL, NSString *))done;
+ (void)loginWithPhone:(NSString *)phone code:(NSString *)code
            completion:(void (^)(BOOL, NSString *))done;
@end

// ★ 纯 C 函数：Tweak.xm 是 Objective-C++，引用时会做 C++ 名字修饰，
//   若不包 extern "C"，.m 导出的未修饰名就对不上 → dyld 找不到符号 →
//   dylib 被卸载 → App 启动即崩。2026-10-15 已因同类问题崩过 7 次。
#ifdef __cplusplus
extern "C" {
#endif
// 工具（Tweak.xm 的网络层翻译会用到）
NSString *BRLoginMd5(NSString *s);
NSString *BRBuildSignedQuery(NSDictionary *params);
NSData  *BRDirectGet(NSString *urlStr, NSInteger *statusOut);

// 改造登录页：输入框改名、注册按钮改成「发送验证码」
void BRRelabelLoginPage(id vc);

#ifdef __cplusplus
}
#endif
