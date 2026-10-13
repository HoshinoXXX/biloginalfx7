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
        BWrite(@"b18.txt", @"B18 已加载 —— 完整源文件集（四处修复后）");
        @try { BRLogInit(); BWrite(@"b18.txt", @"B18 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b18.txt", @"B18 BRLogInit 异常"); }
        @try { [BRStore bootstrap]; BWrite(@"b18.txt", @"B18 BRStore 成功"); } @catch (NSException *e) { BWrite(@"b18.txt", @"B18 BRStore 异常"); }
        @try { [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b18.txt", @"B18 BRSession 成功"); } @catch (NSException *e) { BWrite(@"b18.txt", @"B18 BRSession 异常"); }
        @try { Class c = objc_getClass("BRURLProtocol"); if (c) { [NSURLProtocol registerClass:c]; BWrite(@"b18.txt", @"B18 注册 BRURLProtocol 成功"); } else { BWrite(@"b18.txt", @"B18 BRURLProtocol 类为 nil"); } } @catch (NSException *e) { BWrite(@"b18.txt", @"B18 注册异常"); }
        @try { BOOL b = BRIsBiliHost(@"api.bilibili.com"); BWrite(@"b18.txt", [NSString stringWithFormat:@"B18 BRIsBiliHost = %d", b]); } @catch (NSException *e) { BWrite(@"b18.txt", @"B18 BRIsBiliHost 异常"); }
    }
}