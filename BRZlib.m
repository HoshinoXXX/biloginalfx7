// BRZlib.m —— 见 BRZlib.h
#import "BRZlib.h"
#import "BRLog.h"
#import <dlfcn.h>
#import <string.h>

// ---------------------------------------------------------------------------
// 自己声明 z_stream 与 inflate 系列原型，避免 #import <zlib.h> 带来链接期依赖。
// 布局与 zlib 的 z_stream 完全一致（iOS 上 uInt = unsigned int，uLong = unsigned long）。
// ---------------------------------------------------------------------------
typedef unsigned char  BRBytef;
typedef unsigned int   BRuInt;
typedef unsigned long  BRuLong;

typedef struct {
    BRBytef  *next_in;
    BRuInt    avail_in;
    BRuLong   total_in;
    BRBytef  *next_out;
    BRuInt    avail_out;
    BRuLong   total_out;
    char     *msg;
    void     *state;
    void     *(*zalloc)(void *, BRuInt, BRuInt);
    void      (*zfree)(void *, void *);
    void     *opaque;
    int       data_type;
    BRuLong   adler;
    BRuLong   reserved;
} BRz_stream;

typedef int (*BR_inflateInit2_t)(BRz_stream *, int, const char *, int);
typedef int (*BR_inflate_t)(BRz_stream *, int);
typedef int (*BR_inflateEnd_t)(BRz_stream *);

static BR_inflateInit2_t p_inflateInit2 = NULL;
static BR_inflate_t      p_inflate      = NULL;
static BR_inflateEnd_t   p_inflateEnd   = NULL;
static int               s_zlibReady    = -1;   // -1 未探测 / 0 不可用 / 1 可用

#define BR_Z_OK         0
#define BR_Z_STREAM_END 1
#define BR_Z_BUF_ERROR (-5)
#define BR_Z_NO_FLUSH   0

static void *BRzSym(void *h, const char *n) {
    void *p = dlsym(h, n);
    if (p == NULL) BRERR(@"[zlib] 缺少符号 %s", n);
    return p;
}

// 只探测一次：依次尝试常见路径
static int BRzInit(void) {
    if (s_zlibReady >= 0) return s_zlibReady;
    s_zlibReady = 0;
    static const char *paths[] = {
        "/usr/lib/libz.1.dylib",
        "/usr/lib/libz.dylib",
        "libz.1.dylib",
        "libz.dylib",
        NULL
    };
    for (int i = 0; paths[i] != NULL; i++) {
        void *h = dlopen(paths[i], RTLD_LAZY);
        if (h == NULL) continue;
        p_inflateInit2 = (BR_inflateInit2_t)BRzSym(h, "inflateInit2_");
        p_inflate      = (BR_inflate_t)     BRzSym(h, "inflate");
        p_inflateEnd   = (BR_inflateEnd_t)  BRzSym(h, "inflateEnd");
        if (p_inflateInit2 && p_inflate && p_inflateEnd) {
            s_zlibReady = 1;
            BRINFO(@"[zlib] 运行时加载成功：%s", paths[i]);
            return 1;
        }
        dlclose(h);
        p_inflateInit2 = NULL; p_inflate = NULL; p_inflateEnd = NULL;
    }
    BRERR(@"[zlib] 运行时加载失败，gzip 解压不可用");
    return 0;
}

BOOL BRIsGzipHeader(NSData *d) {
    if (d == nil || [d length] < 2) return NO;
    const unsigned char *b = (const unsigned char *)[d bytes];
    return (b[0] == 0x1f && b[1] == 0x8b);
}

NSData *BRGunzipData(NSData *d) {
    if (!BRIsGzipHeader(d)) return nil;
    if (!BRzInit()) return nil;

    BRz_stream zs;
    memset(&zs, 0, sizeof(zs));
    // 15 + 16 = 自动识别 gzip 头
    if (p_inflateInit2(&zs, 15 + 16, "1.2.11", (int)sizeof(zs)) != BR_Z_OK) {
        BRERR(@"[zlib] inflateInit2 失败");
        return nil;
    }
    zs.next_in  = (BRBytef *)[d bytes];
    zs.avail_in = (BRuInt)[d length];

    NSMutableData *out = [NSMutableData data];
    unsigned char buf[16384];
    int rc = BR_Z_OK;
    while (rc == BR_Z_OK || rc == BR_Z_BUF_ERROR) {
        zs.next_out  = buf;
        zs.avail_out = (BRuInt)sizeof(buf);
        rc = p_inflate(&zs, BR_Z_NO_FLUSH);
        NSUInteger got = sizeof(buf) - zs.avail_out;
        if (got > 0) [out appendBytes:buf length:got];
        if (rc == BR_Z_STREAM_END) break;
        if (rc != BR_Z_OK && rc != BR_Z_BUF_ERROR) break;
        if (rc == BR_Z_BUF_ERROR && got == 0) break;
        if (zs.avail_in == 0 && got == 0) break;
    }
    p_inflateEnd(&zs);
    return ([out length] > 0) ? out : nil;
}
