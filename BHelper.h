// 二分探针公共工具：往多个位置写标记，哪个能写算哪个
#import <Foundation/Foundation.h>

static void BWrite(NSString *name, NSString *text) {
    @try {
        NSData *d = [[NSString stringWithFormat:@"[%@] %@\n", [NSDate date], text]
                     dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *dirs = [NSArray arrayWithObjects:@"/tmp", nil];
        for (NSString *dir in dirs) {
            NSString *p = [dir stringByAppendingPathComponent:name];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
            else { [d writeToFile:p atomically:NO]; }
        }
        NSLog(@"[Bisect] %@", text);
    } @catch (NSException *e) { }
}