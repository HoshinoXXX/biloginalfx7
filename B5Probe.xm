#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRStore.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b5.txt", @"B5 已加载 —— BRLog + BRStore");
        @try { BRLogInit(); BWrite(@"b5.txt", @"B5 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b5.txt", @"B5 BRLogInit 异常"); }
        @try { [BRStore bootstrap]; BWrite(@"b5.txt", @"B5 BRStore bootstrap 成功"); } @catch (NSException *e) { BWrite(@"b5.txt", @"B5 BRStore 异常"); }
        @try {
            long long f = [BRStore fakeAidForReal:1700000000LL];
            BWrite(@"b5.txt", [NSString stringWithFormat:@"B5 fakeAid 返回 %lld", f]);
        } @catch (NSException *e) { BWrite(@"b5.txt", @"B5 fakeAid 异常"); }
    }
}