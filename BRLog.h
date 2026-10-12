//
//  BRLog.h —— 轻量日志（可开关、限流）
//
//  ★ 注意：Tweak.xm 是 Objective-C++（.xm 按 C++ 编译），而 BRLog.m 是纯
//  Objective-C（C 链接）。C 函数若不在头文件里用 extern "C" 声明，
//  ObjC++ 侧会按 C++ 规则对符号改名（mangling），与 .m 提供的 C 符号对不上，
//  链接时就会报 "symbol(s) not found" 并提示「声明可能缺少外部 C」。
//  所以下面这段 extern "C" 是必需的，不要删。
//
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void BRLogInit(void);
BOOL BRLogEnabled(void);

// 日志写入 /var/mobile/biloginalfx7.log（越狱环境可写）；
// 写不了就退化为 NSLog（Xcode / Console.app 可见）。
void BRLogWrite(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#ifdef __cplusplus
}
#endif

#define BRINFO(...) BRLogWrite(@"[I] " __VA_ARGS__)
#define BRDBG(...)  do { if (BRLogEnabled()) BRLogWrite(@"[D] " __VA_ARGS__); } while (0)
#define BRERR(...)  BRLogWrite(@"[E] " __VA_ARGS__)