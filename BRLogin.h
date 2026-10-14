//
//  BRLogin.h —— 短信验证码登录（改造现有登录页）
//

#import <Foundation/Foundation.h>

@interface BRLogin : NSObject
+ (void)sendSmsToPhone:(NSString *)phone completion:(void (^)(BOOL, NSString *))done;
+ (void)loginWithPhone:(NSString *)phone code:(NSString *)code
            completion:(void (^)(BOOL, NSString *))done;
@end

// 工具（Tweak.xm 的网络层翻译会用到）
NSString *BRLoginMd5(NSString *s);
NSString *BRBuildSignedQuery(NSDictionary *params);
NSData  *BRDirectGet(NSString *urlStr, NSInteger *statusOut);

// 改造登录页：输入框改名、注册按钮改成「发送验证码」
void BRRelabelLoginPage(id vc);
