// QQHelperPortPrefs - Settings panel for QQHelperPort
//
// Theos's vendored Preferences headers (PSTableCell.h / PSSpecifier.h) do not
// parse with current clang - they fail with "expected ':'" and the whole
// `Preferences` module fails to build. Rather than fight them, the two classes
// this panel actually needs are declared here and resolved at load time
// through -undefined dynamic_lookup.

#import <UIKit/UIKit.h>

// Minimal forward declarations of the Preferences framework classes we use.
@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (NSArray *)specifiers;
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface PSSpecifier : NSObject
@end

@interface QQHelperPortRootListController : PSListController
@end

@implementation QQHelperPortRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// Value shown by the "log file" row.
- (id)logPath:(PSSpecifier *)spec {
    return @"/tmp/qqhp.log";
}

@end
