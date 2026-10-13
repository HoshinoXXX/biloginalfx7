#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"

// ★ 最小验证：只声明一个 NSURLProtocol 子类，不做任何别的
@interface BRTinyProto : NSURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r;
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r;
- (void)startLoading;
- (void)stopLoading;
@end

@implementation BRTinyProto
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return NO; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading { }
- (void)stopLoading { }
@end

%ctor {
    @autoreleasepool {
        BWrite(@"b21.txt", @"B21 已加载 —— 最小 NSURLProtocol 子类");
        @try { BRLogInit(); } @catch (NSException *e) { }
        @try {
            [NSURLProtocol registerClass:[BRTinyProto class]];
            BWrite(@"b21.txt", @"B21 注册成功");
        } @catch (NSException *e) { BWrite(@"b21.txt", @"B21 注册异常"); }
    }
}