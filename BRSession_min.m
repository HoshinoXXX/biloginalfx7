// BRSession 骨架版 —— 只保留类结构和三个方法签名，方法体全空。
// 用途：判断 BRSession.m 到底是「类本身」还是「某个具体函数」导致加载失败。
#import "BRSession.h"
#import "BRLog.h"

@implementation BRSession

+ (void)bootstrap {
    // 故意什么都不做
}

+ (void)warmUp {
    // 故意什么都不做
}

+ (NSString *)md5:(NSString *)s {
    return @"skeleton";
}

@end