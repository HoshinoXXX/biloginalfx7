#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b14.txt", @"B14Probe 已加载 —— BRSession 第 1 组");
        @try { BRLogInit(); } @catch (NSException *e) { }
        @try { [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b14.txt", @"B14Probe 初始化调用成功"); } @catch (NSException *e) { BWrite(@"b14.txt", @"B14Probe 调用异常"); }
    }
}