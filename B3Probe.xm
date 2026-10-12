#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRStore.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b3.txt", @"B3 已加载");
        @try { BRLogInit(); BWrite(@"b3.txt", @"B3 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b3.txt", @"B3 BRLogInit 异常"); }
        @try { [BRStore bootstrap]; BWrite(@"b3.txt", @"B3 BRStore bootstrap 成功"); } @catch (NSException *e) { BWrite(@"b3.txt", @"B3 BRStore 异常"); }
        @try { [BRSession bootstrap]; BWrite(@"b3.txt", @"B3 BRSession bootstrap 成功"); } @catch (NSException *e) { BWrite(@"b3.txt", @"B3 BRSession 异常"); }
        @try { [BRSession warmUp]; BWrite(@"b3.txt", @"B3 BRSession warmUp 成功"); } @catch (NSException *e) { BWrite(@"b3.txt", @"B3 warmUp 异常"); }
    }
}