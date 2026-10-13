#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRURLProtocol.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b18.txt", @"B18 已加载 —— +BRURLProtocol");
        @try { BRLogInit(); [BRStore bootstrap]; [BRSession bootstrap]; [BRSession warmUp]; } @catch (NSException *e) { }
        @try {
            Class c = objc_getClass("BRURLProtocol");
            BWrite(@"b18.txt", [NSString stringWithFormat:@"B18 BRURLProtocol 类 = %@", c ? @"存在" : @"nil"]);
            if (c) { [NSURLProtocol registerClass:c]; BWrite(@"b18.txt", @"B18 注册成功"); }
        } @catch (NSException *e) { BWrite(@"b18.txt", @"B18 注册异常"); }
    }
}