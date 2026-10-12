#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRURLProtocol.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b4.txt", @"B4 已加载");
        @try { BRLogInit(); BWrite(@"b4.txt", @"B4 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b4.txt", @"B4 BRLogInit 异常"); }
        @try { [BRStore bootstrap]; [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b4.txt", @"B4 Store+Session 成功"); } @catch (NSException *e) { BWrite(@"b4.txt", @"B4 Store+Session 异常"); }
        @try {
            Class c = objc_getClass("BRURLProtocol");
            if (c) { [NSURLProtocol registerClass:c]; BWrite(@"b4.txt", @"B4 BRURLProtocol 注册成功"); }
            else { BWrite(@"b4.txt", @"B4 BRURLProtocol 类不存在"); }
        } @catch (NSException *e) { BWrite(@"b4.txt", @"B4 注册异常"); }
        @try {
            MSHookMessageEx(objc_getClass("NSURLConnection"),
                @selector(initWithRequest:delegate:), (IMP)0, (IMP *)0);
            BWrite(@"b4.txt", @"B4 MSHookMessageEx 调用返回");
        } @catch (NSException *e) { BWrite(@"b4.txt", @"B4 hook 异常"); }
    }
}