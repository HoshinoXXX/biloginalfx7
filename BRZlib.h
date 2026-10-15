// BRZlib.h —— 运行时加载 zlib（不链接 -lz）
//
// 背景：为避免「dylib 因为一个额外依赖而整体加载失败」，
// 这里用 dlopen/dlsym 在运行时取 inflate 系列符号。
// 设备上拿不到 zlib 时优雅降级（返回 nil），而不是让插件彻底不加载。
#import <Foundation/Foundation.h>

// 探测 gzip magic（1f 8b）
BOOL BRIsGzipHeader(NSData *d);

// gunzip；不是 gzip / 失败 / 无 zlib → 返回 nil
NSData *BRGunzipData(NSData *d);
