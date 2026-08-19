#import <Foundation/Foundation.h>

/// 在 @try/@catch 中执行 block，拦截 Objective-C 异常（Swift 无法直接捕获 NSException）。
/// 返回 YES 表示无异常；NO 表示捕获到异常，原因与调用栈已写入 /tmp/macall_exception.log 并打印 NSLog。
BOOL MACatchException(void (^ _Nonnull block)(void));
