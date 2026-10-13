#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b11.txt", @"B11 已加载 —— BRLog + BRSession【完整版】");
        @try { BRLogInit(); [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b11.txt", @"B11 初始化成功"); } @catch (NSException *e) { BWrite(@"b11.txt", @"B11 异常"); }
    }
}