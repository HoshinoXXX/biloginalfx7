#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"

// ★ 对照：同样的类结构，但父类是 NSObject
@interface BRTinyObj : NSObject
+ (BOOL)canInitWithRequest:(NSURLRequest *)r;
- (void)startLoading;
@end

@implementation BRTinyObj
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return NO; }
- (void)startLoading { }
@end

%ctor {
    @autoreleasepool {
        BWrite(@"b22.txt", @"B22 已加载 —— 同样结构但继承 NSObject");
        @try { BRLogInit(); } @catch (NSException *e) { }
        BWrite(@"b22.txt", @"B22 完成");
    }
}