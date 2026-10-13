#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRRouter.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b19.txt", @"B19 已加载 —— BRLog+BRStore+BRSession+BRRouter（无 BRURLProtocol）");
        @try { BRLogInit(); BWrite(@"b19.txt", @"B19 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b19.txt", @"B19 BRLogInit 异常"); }
        @try { [BRStore bootstrap]; [BRSession bootstrap]; [BRSession warmUp]; BWrite(@"b19.txt", @"B19 Store+Session 成功"); } @catch (NSException *e) { BWrite(@"b19.txt", @"B19 Store+Session 异常"); }
    }
}