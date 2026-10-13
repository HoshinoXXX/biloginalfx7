#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b17.txt", @"B17Probe 已加载 —— BRSession h2");
        @try { BRLogInit(); [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b17.txt", @"B17Probe 初始化成功"); } @catch (NSException *e) { BWrite(@"b17.txt", @"B17Probe 异常"); }
    }
}