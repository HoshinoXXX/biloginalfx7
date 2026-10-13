#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b16.txt", @"B16Probe 已加载 —— BRSession h1");
        @try { BRLogInit(); [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b16.txt", @"B16Probe 初始化成功"); } @catch (NSException *e) { BWrite(@"b16.txt", @"B16Probe 异常"); }
    }
}