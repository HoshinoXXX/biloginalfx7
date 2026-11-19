// QQHelperPortPrefs - Settings panel for QQHelperPort
//
// A plain PSListController driven by Root.plist, so every switch is declared
// in one place and stored in NSUserDefaults under com.qqhelperport.tweak.
// The tweak reads the same domain, with /tmp/qqhp-no-* files still usable as an
// override for debugging.

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface QQHelperPortRootListController : PSListController
@end

@implementation QQHelperPortRootListController

- (id)specifiers {
    if (_specifiers == nil) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] retain];
    }
    return _specifiers;
}

// Show the live log path so it can be checked over SSH.
- (id)logPath:(PSSpecifier *)spec {
    return @"/tmp/qqhp.log";
}

@end
