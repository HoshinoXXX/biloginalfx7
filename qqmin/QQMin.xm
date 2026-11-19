// QQMin —— 最小化测试 dylib
//
// 目的：用一个「只做一件事」的 tweak 判断 iOS 7 + MobileSubstrate 到底
// 能不能加载我们构建出的 dylib。
//
//   · 只有构造函数
//   · 只做：在几个候选路径里找一个能写的，写一行文字
//   · 不 import UIKit，不用任何 hook，不碰 runtime
//
// 如果它能写出文件 -> 构建/打包链路没问题，问题在大 dylib 里
// 如果它也不行   -> 问题在构建参数或 iOS 7 的 Substrate 兼容性

#import <Foundation/Foundation.h>

__attribute__((constructor))
static void QQMinInit(void) {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"QQMin loaded\n"];
    [report appendFormat:@"bundle=%@\n", [[NSBundle mainBundle] bundleIdentifier]];
    [report appendFormat:@"home=%@\n", NSHomeDirectory()];
    [report appendFormat:@"time=%f\n", [[NSDate date] timeIntervalSince1970]];

    NSMutableArray *cands = [NSMutableArray array];
    [cands addObject:@"/tmp/qqmin.txt"];
    NSString *home = NSHomeDirectory();
    if (home) {
        [cands addObject:[home stringByAppendingPathComponent:@"Documents/qqmin.txt"]];
        [cands addObject:[home stringByAppendingPathComponent:@"Library/qqmin.txt"]];
        [cands addObject:[home stringByAppendingPathComponent:@"qqmin.txt"]];
    }

    NSData *data = [report dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in cands) {
        if ([fm createFileAtPath:c contents:data attributes:nil]) {
            NSLog(@"[QQMin] wrote %@", c);
        }
    }
}
