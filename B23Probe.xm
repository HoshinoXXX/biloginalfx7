#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"

// ★ 与 B21 完全相同的类，唯一区别是 Makefile 里多链了 CFNetwork
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
        BWrite(@"b23.txt", @"B23 已加载 —— 最小 NSURLProtocol 子类 + 链接 CFNetwork");
        @try { BRLogInit(); } @catch (NSException *e) { }
        @try { [NSURLProtocol registerClass:[BRTinyProto class]]; BWrite(@"b23.txt", @"B23 注册成功"); } @catch (NSException *e) { BWrite(@"b23.txt", @"B23 注册异常"); }
    }
}