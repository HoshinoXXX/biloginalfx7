// BRSession 骨架 + md5（完全不碰 BRCrypto / CommonCrypto）
// 用来区分「md5 这个方法」和「BRCrypto.h 的 dlsym 机制」
#import "BRSession.h"
#import "BRLog.h"

@implementation BRSession

+ (void)bootstrap { }
+ (void)warmUp { }

+ (NSString *)md5:(NSString *)s {
    // 假的：不调用任何外部加密函数
    return [NSString stringWithFormat:@"fake-md5-%lu", (unsigned long)[s length]];
}

@end