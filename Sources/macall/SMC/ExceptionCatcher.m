#import "ExceptionCatcher.h"

BOOL MACatchException(void (^ block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSString *reason = [exception reason] ?: @"(no reason)";
        NSArray<NSString *> *symbols = [exception callStackSymbols];
        NSString *msg = [NSString stringWithFormat:@"[MACatchException] %@\n%@",
                         reason, [symbols componentsJoinedByString:@"\n"]];
        // 写入独立诊断文件（绕开正式日志轮转，便于定位单个功能安装抛出的异常）。
        FILE *f = fopen("/tmp/macall_exception.log", "a");
        if (f) {
            fprintf(f, "%s\n", [msg UTF8String]);
            fclose(f);
        }
        NSLog(@"%@", msg);
        return NO;
    }
}
