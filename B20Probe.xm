#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRRouter.h"
#import "BRURLProtocol.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b20.txt", @"B20 已加载 —— 上面那套 + BRURLProtocol");
        @try { BRLogInit(); [BRStore bootstrap]; [BRSession bootstrap]; [BRSession warmUp]; } @catch (NSException *e) { }
        @try { Class c = objc_getClass("BRURLProtocol"); if (c) { [NSURLProtocol registerClass:c]; BWrite(@"b20.txt", @"B20 注册成功"); } else { BWrite(@"b20.txt", @"B20 类为 nil"); } } @catch (NSException *e) { BWrite(@"b20.txt", @"B20 注册异常"); }
    }
}