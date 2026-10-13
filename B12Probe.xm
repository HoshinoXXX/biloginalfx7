#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b12.txt", @"B12 已加载 —— 骨架 + 真实 md5（BRCrypto/dlsym 路径）");
        @try { BRLogInit(); } @catch (NSException *e) { }
        @try {
            NSString *m = [BRSession md5:@"abc"];
            BWrite(@"b12.txt", [NSString stringWithFormat:@"B12 md5(abc) = %@", m]);
        } @catch (NSException *e) { BWrite(@"b12.txt", @"B12 md5 抛异常"); }
    }
}