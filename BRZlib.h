// BRZlib.h —— 运行时加载 zlib（不链接 -lz）
//
// 背景：为避免「dylib 因为一个额外依赖而整体加载失败」，
// 这里用 dlopen/dlsym 在运行时取 inflate 系列符号。
// 设备上拿不到 zlib 时优雅降级（返回 nil），而不是让插件彻底不加载。
#import <Foundation/Foundation.h>

// ★★★ 必须 extern "C" ★★★
//   Tweak.xm 是 .xm = Objective-C++，它引用这些**纯 C 函数**时会按 C++ 规则
//   修饰名字（BRIsGzipHeader → __Z14BRIsGzipHeaderP6NSData），而 BRZlib.m 是
//   纯 ObjC/转 C 编译，导出的是未修饰名 → dyld 解析失败 →
//   整个 dylib 被卸载，App 一启动就崩溃：
//     "Symbol not found: __Z14BRIsGzipHeaderP6NSData"
//   2026-10-15 实测踩过这个坑，B 站连崩 7 次。
#ifdef __cplusplus
extern "C" {
#endif

// 探测 gzip magic（1f 8b）
BOOL BRIsGzipHeader(NSData *d);

// gunzip；不是 gzip / 失败 / 无 zlib → 返回 nil
NSData *BRGunzipData(NSData *d);

#ifdef __cplusplus
}
#endif
