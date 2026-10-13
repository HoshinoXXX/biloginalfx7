#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b8.txt", @"B8 已加载 —— BRLog + BRSession(已修 CC_MD5)");
        @try { BRLogInit(); BWrite(@"b8.txt", @"B8 BRLogInit 成功"); } @catch (NSException *e) { BWrite(@"b8.txt", @"B8 BRLogInit 异常"); }
        @try { [BRSession bootstrap]; BWrite(@"b8.txt", @"B8 bootstrap 成功"); } @catch (NSException *e) { BWrite(@"b8.txt", @"B8 bootstrap 异常"); }
        @try { [BRSession warmUp]; BWrite(@"b8.txt", @"B8 warmUp 成功"); } @catch (NSException *e) { BWrite(@"b8.txt", @"B8 warmUp 异常"); }
        @try { NSString *m = [BRSession md5:@"abc"]; BWrite(@"b8.txt", [NSString stringWithFormat:@"B8 md5 返回 %@", m]); } @catch (NSException *e) { BWrite(@"b8.txt", @"B8 md5 异常"); }
    }
}