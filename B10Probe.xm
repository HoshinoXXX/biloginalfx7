#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b10.txt", @"B10 已加载 —— BRLog + BRSession【骨架版】");
        @try { BRLogInit(); BWrite(@"b10.txt", @"B10 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b10.txt", @"B10 BRLogInit 异常"); }
        @try { [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b10.txt", @"B10 骨架方法调用成功"); } @catch (NSException *e) { BWrite(@"b10.txt", @"B10 调用异常"); }
    }
}