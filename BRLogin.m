//
//  BRLogin.m —— 短信验证码登录（改造现有登录页，不重建 UI）
//
//  用户要求：
//    ① 「我的」页面的注册按钮去掉
//    ② 登录页的注册按钮：文字改成「发送验证码」，功能改成发验证码
//    ③ 密码输入框文字改成「验证码」
//    ④ 密码框的功能从「密码校验」变成「验证码校验」（= API 层翻译）
//    ⑤ 手机号/账户/邮箱输入框文字改成「输入手机号」
//
//  设计：登录按钮的原有流程**不动** —— 只把它的网络请求在插件里翻译：
//        /api/oauth2/login 的 username -> mobile、password -> code，
//        目标改成 /x/passport-login/login/sms。
//

#import <UIKit/UIKit.h>
#import "BRLogin.h"
#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRCrypto.h"
#import <objc/runtime.h>

#define BR_LOGIN_APPKEY  @"dfca71928277209b"
#define BR_LOGIN_APPSEC  @"b5475a8825547a4fc26c7d518eaaa02e"
#define BR_LOGIN_BUILD   @"2001100"

#pragma mark - 工具

NSString *BRLoginMd5(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char dg[16];
    if (d == nil || BRCC_MD5(d.bytes, (unsigned int)d.length, dg) == NULL) return nil;
    NSMutableString *h = [NSMutableString string];
    for (int i = 0; i < 16; i++) [h appendFormat:@"%02x", dg[i]];
    return h;
}

NSString *BRBuildSignedQuery(NSDictionary *params) {
    NSArray *keys = [[params allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *k in keys) {
        if ([k isEqualToString:@"sign"]) continue;
        id v = [params objectForKey:k];
        if (v == nil || v == [NSNull null]) continue;
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
    }
    NSString *raw = [pairs componentsJoinedByString:@"&"];
    NSString *sign = BRLoginMd5([raw stringByAppendingString:BR_LOGIN_APPSEC]);
    return sign ? [raw stringByAppendingFormat:@"&sign=%@", sign] : raw;
}

NSData *BRDirectGet(NSString *urlStr, NSInteger *statusOut) {
    @try {
        NSURL *u = [NSURL URLWithString:urlStr];
        if (u == nil) return nil;
        Class reqCls = NSClassFromString(@"NSMutableURLRequest");
        Class connCls = NSClassFromString(@"NSURLConnection");
        if (reqCls == Nil || connCls == Nil) return nil;
        id req = [reqCls requestWithURL:u];
        [req setTimeoutInterval:15];
        [req setValue:@"Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android"
    forHTTPHeaderField:@"User-Agent"];
        NSString *ck = [BRSession cookie];
        if ([ck length]) [req setValue:ck forHTTPHeaderField:@"Cookie"];
        id resp = nil; NSError *err = nil;
        NSData *d = [connCls sendSynchronousRequest:req returningResponse:&resp error:&err];
        if (statusOut != NULL) {
            @try { *statusOut = [[resp valueForKey:@"statusCode"] integerValue]; }
            @catch (NSException *e) { *statusOut = 0; }
        }
        return d;
    } @catch (NSException *e) {
        BRERR(@"[登录] 直连失败: %@", [e description]);
        return nil;
    }
}

@interface BRLoginSmsFlow : NSObject
@property (nonatomic, copy) NSString *phone;
+ (instancetype)shared;
- (void)onSendCode:(id)sender;
@end

#pragma mark - 发验证码 / 短信登录

@implementation BRLogin

+ (void)sendSmsToPhone:(NSString *)phone completion:(void (^)(BOOL, NSString *))done {
    NSString *ph = [phone stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([ph length] < 11) { if (done) done(NO, @"手机号格式不对"); return; }

    NSString *buvid = [BRSession buvid3] ?: @"";
    long long ms = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    [p setObject:ph forKey:@"mobile"];
    [p setObject:@"86" forKey:@"country_code"];
    [p setObject:@"86" forKey:@"cid"];
    [p setObject:BR_LOGIN_BUILD forKey:@"build"];
    [p setObject:@"main.my-information.my-login.0.click" forKey:@"from_pv"];
    [p setObject:@"phone" forKey:@"device"];
    [p setObject:@"vivo" forKey:@"device_name"];
    [p setObject:@"Android14vivo" forKey:@"device_platform"];
    [p setObject:@"android_hd" forKey:@"mobi_app"];
    [p setObject:@"android" forKey:@"platform"];
    if ([buvid length]) {
        [p setObject:buvid forKey:@"buvid"];
        [p setObject:buvid forKey:@"local_id"];
        [p setObject:buvid forKey:@"bili_local_id"];
        [p setObject:buvid forKey:@"device_id"];
        NSString *sid = BRLoginMd5([NSString stringWithFormat:@"%@%lld", buvid, ms]);
        if (sid) [p setObject:sid forKey:@"login_session_id"];
    }
    NSString *url = [NSString stringWithFormat:
        @"https://passport.bilibili.com/x/passport-login/sms/send?%@", BRBuildSignedQuery(p)];
    BRINFO(@"[登录] 发验证码 -> %@", ph);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger st = 0;
        NSData *d = BRDirectGet(url, &st);
        NSInteger code = -1; NSString *msg = @"无响应";
        if (d) {
            @try {
                id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
                id c = [j objectForKey:@"code"], m = [j objectForKey:@"message"];
                if ([c respondsToSelector:@selector(integerValue)]) code = [c integerValue];
                if ([m isKindOfClass:[NSString class]]) msg = m;
            } @catch (NSException *e) { }
        }
        BRINFO(@"[登录] 发验证码回应: HTTP %ld code=%ld msg=%@", (long)st, (long)code, msg);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done((code == 0), msg); });
    });
}

+ (void)loginWithPhone:(NSString *)phone code:(NSString *)code
            completion:(void (^)(BOOL, NSString *))done {
    NSString *ph = [phone stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *cd = [code stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([ph length] < 11) { if (done) done(NO, @"手机号格式不对"); return; }
    if ([cd length] < 4)  { if (done) done(NO, @"验证码格式不对"); return; }

    NSString *buvid = [BRSession buvid3] ?: @"";
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    [p setObject:ph forKey:@"mobile"];
    [p setObject:cd forKey:@"code"];
    [p setObject:@"86" forKey:@"country_code"];
    [p setObject:BR_LOGIN_BUILD forKey:@"build"];
    [p setObject:@"android_hd" forKey:@"mobi_app"];
    [p setObject:@"android" forKey:@"platform"];
    [p setObject:@"master" forKey:@"channel"];
    [p setObject:@"zh_CN" forKey:@"c_locale"];
    [p setObject:@"zh_CN" forKey:@"s_locale"];
    [p setObject:@"{\"appId\":5,\"platform\":3,\"version\":\"2.0.1\",\"abtest\":\"\"}" forKey:@"statistics"];
    if ([buvid length]) {
        [p setObject:buvid forKey:@"buvid"];
        [p setObject:buvid forKey:@"local_id"];
        [p setObject:buvid forKey:@"bili_local_id"];
        [p setObject:buvid forKey:@"device_id"];
    }
    NSString *url = [NSString stringWithFormat:
        @"https://passport.bilibili.com/x/passport-login/login/sms?%@", BRBuildSignedQuery(p)];
    BRINFO(@"[登录] 提交短信登录 -> %@ code=%@", ph, cd);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger st = 0;
        NSData *d = BRDirectGet(url, &st);
        NSInteger code = -1; NSString *msg = @"无响应";
        if (d) {
            @try {
                id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
                id c = [j objectForKey:@"code"], m = [j objectForKey:@"message"];
                if ([c respondsToSelector:@selector(integerValue)]) code = [c integerValue];
                if ([m isKindOfClass:[NSString class]]) msg = m;
                id data = [j objectForKey:@"data"];
                if ([data isKindOfClass:[NSDictionary class]]) {
                    NSMutableArray *ck = [NSMutableArray array];
                    for (NSString *k in @[@"cookie_info", @"sso"]) {
                        id ci = [data objectForKey:k];
                        if ([ci isKindOfClass:[NSDictionary class]]) {
                            id cs = [ci objectForKey:@"cookies"];
                            if ([cs isKindOfClass:[NSArray class]]) {
                                for (id c2 in cs) {
                                    if ([c2 isKindOfClass:[NSDictionary class]]) {
                                        id n = [c2 objectForKey:@"name"], v = [c2 objectForKey:@"value"];
                                        if (n && v) [ck addObject:[NSString stringWithFormat:@"%@=%@", n, v]];
                                    }
                                }
                            }
                        }
                    }
                    if ([ck count]) {
                        [BRSession setUserCookie:[ck componentsJoinedByString:@"; "]];
                        BRINFO(@"[登录] 已保存 %lu 个 Cookie", (unsigned long)[ck count]);
                    }
                }
            } @catch (NSException *e) { }
        }
        BRINFO(@"[登录] 登录回应: HTTP %ld code=%ld msg=%@", (long)st, (long)code, msg);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done((code == 0), msg); });
    });
}

@end

#pragma mark - 登录页改造

static char kBRLoginDoneKey;

static void BRCollectTextFields(UIView *v, NSMutableArray *out) {
    if (v == nil) return;
    if ([v isKindOfClass:[UITextField class]]) [out addObject:v];
    for (UIView *s in [v subviews]) BRCollectTextFields(s, out);
}

static void BRCollectButtons(UIView *v, NSMutableArray *out) {
    if (v == nil) return;
    if ([v isKindOfClass:[UIButton class]]) [out addObject:v];
    for (UIView *s in [v subviews]) BRCollectButtons(s, out);
}

static void BRCollectTextFields(UIView *v, NSMutableArray *out) {
    if (v == nil) return;
    if ([v isKindOfClass:[UITextField class]]) [out addObject:v];
    NSArray *subs = [v subviews];
    for (NSUInteger i = 0; i < [subs count]; i++) {
        BRCollectTextFields([subs objectAtIndex:i], out);
    }
}

static void BRCollectButtons(UIView *v, NSMutableArray *out) {
    if (v == nil) return;
    if ([v isKindOfClass:[UIButton class]]) [out addObject:v];
    NSArray *subs = [v subviews];
    for (NSUInteger i = 0; i < [subs count]; i++) {
        BRCollectButtons([subs objectAtIndex:i], out);
    }
}

// 真正的改造逻辑。会被 performSelector:afterDelay: 反复调用（对付 cell 复用），
// 所有 setter 都各自包 @try，任何异常都不会影响 App。
void BRRelabelLoginPage(id vc) {
    if (vc == nil) return;
    @try {
        UIView *root = [vc view];
        if (root == nil) return;

        NSMutableArray *tfs = [NSMutableArray array];
        BRCollectTextFields(root, tfs);
        for (NSUInteger i = 0; i < [tfs count]; i++) {
            UITextField *tf = [tfs objectAtIndex:i];
            @try {
                if (i == 0) {
                    [tf setPlaceholder:@"输入手机号"];
                    [tf setKeyboardType:3];
                } else if (i == 1) {
                    [tf setPlaceholder:@"验证码"];
                    [tf setSecureTextEntry:NO];
                    [tf setKeyboardType:3];
                }
            } @catch (NSException *e) { }
        }

        NSMutableArray *btns = [NSMutableArray array];
        BRCollectButtons(root, btns);
        NSMutableString *titles = [NSMutableString string];
        for (NSUInteger i = 0; i < [btns count]; i++) {
            UIButton *b = [btns objectAtIndex:i];
            NSString *ti = @"";
            @try { ti = [b titleForState:0] ?: @""; } @catch (NSException *e) { }
            if ([titles length] < 200) [titles appendFormat:@"[%@]", ti];
            if ([ti rangeOfString:@"注册"].location != NSNotFound ||
                [ti rangeOfString:@"註冊"].location != NSNotFound) {
                @try {
                    [b setTitle:@"发送验证码" forState:0];
                    [b addTarget:[BRLoginSmsFlow shared]
                          action:@selector(onSendCode:)
                forControlEvents:(1 << 6)];
                } @catch (NSException *e) { }
            }
        }
        BRINFO(@"[登录] %@ 输入框=%lu 按钮=[%@]",
               NSStringFromClass([vc class]),
               (unsigned long)[tfs count], titles);
    } @catch (NSException *e) {
        BRERR(@"[登录] 改造失败: %@", [e description]);
    }
}

@implementation BRLoginSmsFlow

+ (instancetype)shared {
    static BRLoginSmsFlow *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[BRLoginSmsFlow alloc] init]; });
    return s;
}

- (void)onSendCode:(id)sender {
    NSString *ph = self.phone;
    if (![ph length]) {
        @try {
            Class appCls = NSClassFromString(@"UIApplication");
            id app = [appCls performSelector:@selector(sharedApplication)];
            id win = [app performSelector:@selector(keyWindow)];
            UIViewController *vc = [win performSelector:@selector(rootViewController)];
            NSMutableArray *tfs = [NSMutableArray array];
            BRCollectTextFields([vc view], tfs);
            if ([tfs count]) ph = [[tfs objectAtIndex:0] text];
        } @catch (NSException *e) { }
    }
    ph = [(ph ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([ph length] < 11) { [self toast:@"请先在第一个输入框里输入手机号"]; return; }
    self.phone = ph;

    [self toast:@"正在发送验证码…"];
    [BRLogin sendSmsToPhone:ph completion:^(BOOL ok, NSString *msg) {
        [self toast:ok ? @"验证码已发送，请查收短信" : [NSString stringWithFormat:@"发送失败：%@", msg]];
    }];
}

- (void)toast:(NSString *)s {
    BRINFO(@"[登录] %@", s);
    @try {
        Class alertCls = NSClassFromString(@"UIAlertView");
        id a = [[alertCls alloc] initWithTitle:@"短信登录" message:s delegate:nil
                             cancelButtonTitle:@"好" otherButtonTitles:nil];
        [a performSelectorOnMainThread:@selector(show) withObject:nil waitUntilDone:NO];
    } @catch (NSException *e) { }
}

@end
