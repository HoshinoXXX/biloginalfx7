#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b15.txt", @"B15Probe 已加载 —— BRSession 第 2 组");
        @try { BRLogInit(); } @catch (NSException *e) { }
        @try { [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b15.txt", @"B15Probe 初始化调用成功"); } @catch (NSException *e) { BWrite(@"b15.txt", @"B15Probe 调用异常"); }
    }
}