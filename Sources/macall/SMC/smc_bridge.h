// Bridging header: exposes the vendored SMC C library (smc.c) to Swift.
// The C functions/types (SMCOpen, SMCReadKey, SMCKeyData_t, SMCVal_t, …)
// become available to the rest of the macall module via this header.
#ifndef SMC_BRIDGE_H
#define SMC_BRIDGE_H
#include "smc.h"
// 暴露 ObjC 异常桥：让 Swift 能拦截单个功能安装时抛出的 NSException，
// 避免一个功能炸掉就拖垮整个 app 启动。
#include "ExceptionCatcher.h"
#endif
