#import "BRLog.h"
#import <stdarg.h>

// ★ 本文件在 ARC 下编译（Makefile 里有 -fobjc-arc），
//   所以绝对不能出现 retain / release / autorelease / dealloc 里调 [super dealloc]。
//   （之前写成手动引用计数，直接编译失败。）
static BOOL gEnabled = YES;
static NSString *gLogPath = nil;          // 静态变量在 ARC 下默认就是强引用
static NSLock *gLock = nil;
static NSMutableDictionary *gThrottle = nil;

// 确保目录存在并可写；返回 YES 表示可用
static BOOL BREnsureDir(NSString *d) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:d isDirectory:&isDir] || !isDir) {
        [fm createDirectoryAtPath:d
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];
    }
    return [fm isWritableFileAtPath:d];
}

// ★ 日志路径三级降级。
//   背景：哔哩哔哩是**沙盒进程**，从它内部往 /var/mobile 写文件很可能被
//   沙盒拒绝。所以不能假定共享目录可写，必须实际探测，并且一定要有一个
//   「沙盒内」的兜底路径 —— App 自己的容器（NSHomeDirectory）必定可写。
static NSString *BRLogPickPath(void) {
    // ★★ 顺序关键：先试「App 自己的容器」。
    //   原因：BREnsureDir 用的是 isWritableFileAtPath:，它只看 POSIX 权限、
    //   **不看沙盒规则** —— 于是 /var/mobile/bilifix 与 /tmp 会被误判成可写，
    //   实际写入被沙盒静默拒绝 → 日志文件根本不会产生。
    //   （App 沙盒里的 Documents 是实际验证过可写的：aidmap.txt 就写在那里。）
    NSString *home = NSHomeDirectory();
    if (home != nil && [home length] > 0) {
        NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
        if (BREnsureDir(docs)) {
            return [docs stringByAppendingPathComponent:@"biloginalfx7.log"];
        }
    }

    // ② 越狱共享目录（方便 cat 查看；仅当确实可写时才会命中）
    NSArray *shared = [NSArray arrayWithObjects:
                       @"/var/mobile/bilifix",
                       @"/tmp", nil];
    for (NSString *d in shared) {
        if (BREnsureDir(d)) {
            return [d stringByAppendingPathComponent:@"biloginalfx7.log"];
        }
    }

    // ③ 都不行 → 只走 NSLog
    return nil;
}

void BRLogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [[NSLock alloc] init];
        gThrottle = [[NSMutableDictionary alloc] init];

        gLogPath = BRLogPickPath();

        // ★ 这一行会同时进 syslog —— 即使文件写不了，
        //   也能从 syslog 判断插件是否加载、有没有写文件的能力。
        if (gLogPath != nil) {
            NSLog(@"[BiloginalfX7] 日志文件: %@", gLogPath);
        } else {
            NSLog(@"[BiloginalfX7] 无法写日志文件（沙盒限制），仅使用 NSLog");
            gEnabled = NO;
        }
    });
}

BOOL BRLogEnabled(void) { return gEnabled; }

void BRLogWrite(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (msg == nil) return;

    // 限流：相同内容 30 秒内只写一次
    [gLock lock];
    NSDate *now = [NSDate date];
    NSDate *last = [gThrottle objectForKey:msg];
    if (last != nil && [now timeIntervalSinceDate:last] < 30.0) {
        [gLock unlock];
        return;
    }
    [gThrottle setObject:now forKey:msg];
    if ([gThrottle count] > 400) [gThrottle removeAllObjects];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"MM-dd HH:mm:ss"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [df stringFromDate:now], msg];
    [gLock unlock];

    // NSLog 始终输出（进 syslog），不受沙盒影响
    NSLog(@"[BiloginalfX7] %@", msg);

    if (gLogPath != nil) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (fh == nil) {
            [line writeToFile:gLogPath atomically:NO
                     encoding:NSUTF8StringEncoding error:NULL];
        } else {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) { }
        }
    }
}