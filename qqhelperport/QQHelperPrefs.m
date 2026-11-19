// QQHelperPrefs —— 自建的面板（替換 2019 年那個在 iOS 7 上會崩的 bundle）
//
// 原版 QQHelper.bundle 的二进制是 2019 年编的，在 iOS 7.1.1 上一加载就抛异常
// （Preferences EXC_CRASH / SIGABRT）。与其依赖它，不如自己写一个：
//   · 自己声明 PSListController / PSSpecifier，不 import Theos 里那套会报错的头
//   · 布局走 Resources/Root.plist，开关全部落在 QQHelper 这个 defaults 域
//   · 最低目标 iOS 7.0，和 tweak 保持一致

#import <UIKit/UIKit.h>

@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (NSArray *)specifiers;
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface PSSpecifier : NSObject
@end

@interface QQHelperRootListController : PSListController
@end

@implementation QQHelperRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (id)logPath:(PSSpecifier *)spec {
    return @"/tmp/qqhelper.log";
}

@end
