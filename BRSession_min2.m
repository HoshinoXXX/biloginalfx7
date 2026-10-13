// BRSession 骨架 + 真实 md5 —— 用来判断 BRCrypto.h 的 dlsym 路径是否就是问题
#import "BRSession.h"
#import "BRLog.h"
#import "BRCrypto.h"

@implementation BRSession

+ (void)bootstrap { }
+ (void)warmUp { }

// ★ 这里走 BRCrypto.h 的 BRCC_MD5（内部用 dlopen/dlsym）
+ (NSString *)md5:(NSString *)s {
    if (!s) return @"";
    const char *c = [s UTF8String];
    unsigned char d[BRCC_MD5_DIGEST_LENGTH];
    BRCC_MD5(c, (BRCC_LONG)strlen(c), d);
    NSMutableString *o = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < BRCC_MD5_DIGEST_LENGTH; i++) [o appendFormat:@"%02x", d[i]];
    return o;
}

@end