#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b2.txt", @"B2 已加载 —— 准备调用 BRLogInit");
        @try { BRLogInit(); BWrite(@"b2.txt", @"B2 BRLogInit 成功"); }
        @catch (NSException *e) { BWrite(@"b2.txt", @"B2 BRLogInit 抛异常"); }
        @try { BRINFO(@"B2 日志系统工作正常"); BWrite(@"b2.txt", @"B2 BRINFO 成功"); }
        @catch (NSException *e) { BWrite(@"b2.txt", @"B2 BRINFO 抛异常"); }
    }
}