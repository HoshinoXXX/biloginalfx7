#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b6.txt", @"B6 已加载 —— BRLog + BRSession");
        @try { BRLogInit(); BWrite(@"b6.txt", @"B6 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b6.txt", @"B6 BRLogInit 异常"); }
        @try { [BRSession bootstrap]; BWrite(@"b6.txt", @"B6 BRSession bootstrap 成功"); } @catch (NSException *e) { BWrite(@"b6.txt", @"B6 BRSession 异常"); }
        @try { [BRSession warmUp]; BWrite(@"b6.txt", @"B6 BRSession warmUp 成功"); } @catch (NSException *e) { BWrite(@"b6.txt", @"B6 warmUp 异常"); }
    }
}