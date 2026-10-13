#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRStore.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b7.txt", @"B7 已加载 —— BRLog + BRStore");
        @try { BRLogInit(); [BRStore bootstrap]; BWrite(@"b7.txt", @"B7 初始化成功"); } @catch (NSException *e) { BWrite(@"b7.txt", @"B7 异常"); }
    }
}