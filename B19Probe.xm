#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRRouter.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b19.txt", @"B19 已加载 —— +BRRouter");
        @try { BRLogInit(); [BRStore bootstrap]; [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b19.txt", @"B19 初始化成功"); } @catch (NSException *e) { BWrite(@"b19.txt", @"B19 异常"); }
    }
}