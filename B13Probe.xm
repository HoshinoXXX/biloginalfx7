#import <Foundation/Foundation.h>
#import "BHelper.h"
#import "BRLog.h"
#import "BRSession.h"
%ctor {
    @autoreleasepool {
        BWrite(@"b13.txt", @"B13 已加载 —— 骨架 + 假 md5（不碰 dlsym）");
        @try { BRLogInit(); } @catch (NSException *e) { }
        @try { BWrite(@"b13.txt", [NSString stringWithFormat:@"B13 md5 = %@", [BRSession md5:@"abc"]]); } @catch (NSException *e) { }
    }
}