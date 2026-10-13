//
//  BRCrypto.h —— CommonCrypto 的运行时解析垫片
//
//  ── 为什么需要这个文件 ────────────────────────────────────────
//  直接写 CC_MD5(...) 会在 dylib 里留下一个**未定义符号** _CC_MD5，
//  而它既不在 LC_LOAD_DYLIB 列表里（theos 不会自动链 libcommonCrypto），
//  也不是 ObjC 运行时符号 —— 只能靠 dyld 在**加载瞬间**从全局命名空间解析。
//
//  实测：一旦解析失败，整个 dlopen 就返回 NULL，
//        SubstrateLoader 随即把 dylib 卸载，表现为
//            dyld: loaded:   .../BiloginalfX7.dylib
//            dyld: unloaded: .../BiloginalfX7.dylib
//        构造函数一行都不会执行（日志/里程碑全空）。
//
//  改成 dlsym 之后，dylib 里不再有 _CC_MD5 这个未定义符号，
//  解析失败的时机从「加载期」推迟到「真正调用时」，不会再拖垮 dlopen。
//  ─────────────────────────────────────────────────────────────
//

#ifndef BR_CRYPTO_H
#define BR_CRYPTO_H

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <string.h>

typedef uint32_t BRCC_LONG;
#define BRCC_MD5_DIGEST_LENGTH 16

typedef unsigned char *(*BRCC_MD5_FN)(const void *data, BRCC_LONG len, unsigned char *md);

// 解析一次，缓存住。找不到就返回 NULL（调用方自己兜底）。
static inline BRCC_MD5_FN BRCCMD5Func(void) {
    static BRCC_MD5_FN fn = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        void *h = dlopen("/usr/lib/libcommonCrypto.dylib", RTLD_LAZY);
        if (!h) h = dlopen("/usr/lib/system/libcommonCrypto.dylib", RTLD_LAZY);
        if (h) fn = (BRCC_MD5_FN)dlsym(h, "CC_MD5");
        if (!fn) fn = (BRCC_MD5_FN)dlsym(RTLD_DEFAULT, "CC_MD5");
        if (!fn) fn = (BRCC_MD5_FN)dlsym(RTLD_DEFAULT, "CC_MD5_j");
    }
    return fn;
}

// 与系统 CC_MD5 同签名。拿不到函数时输出全 0 并返回 NULL。
static inline unsigned char *BRCC_MD5(const void *data, BRCC_LONG len, unsigned char *md) {
    BRCC_MD5_FN fn = BRCCMD5Func();
    if (fn) return fn(data, len, md);
    if (md) memset(md, 0, BRCC_MD5_DIGEST_LENGTH);
    return NULL;
}

#endif