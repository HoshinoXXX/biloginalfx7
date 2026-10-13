#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRRouter.h"
#import "BRURLProtocol.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b9.txt", @"B9 已加载 —— BRLog + BRRouter + BRURLProtocol");
        @try { BRLogInit(); BWrite(@"b9.txt", @"B9 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b9.txt", @"B9 BRLogInit 异常"); }
        @try { BOOL b = BRIsBiliHost(@"api.bilibili.com"); BWrite(@"b9.txt", [NSString stringWithFormat:@"B9 BRIsBiliHost 返回 %d", b]); } @catch (NSException *e) { BWrite(@"b9.txt", @"B9 BRIsBiliHost 异常"); }
        @try { Class c = objc_getClass("BRURLProtocol"); BWrite(@"b9.txt", [NSString stringWithFormat:@"B9 BRURLProtocol 类 = %@", c ? @"存在" : @"nil"]); } @catch (NSException *e) { BWrite(@"b9.txt", @"B9 取类异常"); }
    }
}