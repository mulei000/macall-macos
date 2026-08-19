# macall 项目长期记忆

macOS 菜单栏工具 App，Swift + swiftc 直编（无 SwiftPM）。目录 `macall/`。

## 一、构建与运行铁律

- `bash build.sh`：目标 `arm64-apple-macosx15.0`，Swift 6.3.3，单一模块（`Sources/Defaults/*` 与 `Sources/macall/*` 同一次 swiftc 调用）。固定证书 `macall Code Signing` 保留 TCC 权限，跨版本更新无需重新授权。产物只到 `~/Desktop/macall.app`。
- **版本号单一事实来源**：build.sh 顶部 `APP_VERSION_NUM` / `APP_BUILD`。PlistBuddy 注入用「Print 探测→Set 否则 Add」，不要 `2>/dev/null || true` 吞错（曾卡在 build 20）。
- **`bash build.sh | tail` 会掩盖退出码**（管道取最后一段）。判据用 `bash build.sh > log 2>&1; echo $?` 或 grep `error:`。
- **运行实例保护**：只构建到桌面，不启动、不覆盖 `/Applications/macall.app`，除非用户明确下令。

## 二、架构要点

- **Configuration 是 struct，存在两份副本**：`SettingsModel.config`（界面）与 `FeatureRegistry.config`（驱动运行时+全局热键）。只改前者不生效（`registry.reloadAll()` 读后者）。新增配置项必须走 `SettingsModel` 的 setHotkey/resetHotkey/setFeatureEnabled（内部 save() 同步），或改完显式同步 `registry.config`。
- **功能注册真入口是 `AppDelegate.features` 数组**。`Feature.defaultFeatures()` 与 `Feature.menuItems()` 都是**死代码**（从未被调用/消费），新功能只加那里等于没装（剪贴板曾踩，build 22 修）。
- **弹窗高度几何**：状态栏按钮在菜单栏内（`visibleFrame` 之上）。「按钮下方可用高度」必须用 `screen.visibleFrame.height`，绝不能用 `buttonFrame.minY - visibleFrame.minY`（≈0）。
- **不要 `import Defaults`**：同模块内直接写 `Defaults[...]` / `@Default`，写 import 会报 no such module。
- **Swift 6 无 `-strict-concurrency` 也报 actor 隔离错**：模块整体只跑主线程时，去掉多余 `@MainActor`（如 ClipboardHistoryStore）比到处 `MainActor.assumeIsolated` 干净。
- **SMC 直连可用**（`Sources/macall/SMC/`，无需特权 Helper）。`SystemMonitor` 每 2s 采样温度/风扇/功率，无风扇机型返回 nil → UI 显「—」。
- 参考源码：`~/Desktop/maconitor-source-0.4.35.zip`、`~/Desktop/Macindow-source-11.0.zip`。

## 三、★ 崩溃定位方法论（build 38→39 血泪，最高优先级）

**三处日志，可信度递减：**
1. `~/Library/Logs/DiagnosticReports/macall-*.ips` —— **系统报告，已符号化，唯一权威**。首行是头部 JSON、第二行起才是主报告，解析要 `raw.split("\n",1)[1]` 再 `json.loads`。看 `faultingThread` + `threads[].frames[].imageOffset`。
2. `~/Library/Application Support/macall/Crashes/crash-*.log` —— 自建，build 39 起记录 PC / imageOffset / 链接地址。
3. `~/Library/Logs/macall/crash.log` —— **build 39 已删除**的旧重复实现（曾与 2 并存、互相覆盖信号处理器，是「日志到底在哪」的元凶）。老文件仍在，用了 `backtrace_symbols` 反而比 2 更可读。

**⚠️ 信号处理器内 `backtrace()` 在 arm64 上重建的栈不可靠**，build 38 排查时它把我引到 `updateUptimeText`（完全无关）。别信它。

**从 imageOffset 定位源码行（屡试不爽）：**
```sh
dwarfdump --uuid <binary>          # 先核对 UUID 与 .ips 一致
otool -arch arm64 -tV -j <binary> > /tmp/d.txt
# 链接地址 = 0x100000000 + imageOffset，在 d.txt 里搜
grep -n "<链接地址>" /tmp/d.txt    # 找跳到该 brk 的分支
```
- **`brk #0x1` = Swift 运行时陷阱**（EXC_BREAKPOINT/SIGTRAP）。它们被 LLVM 集中排在函数尾部，需反查是哪条分支跳过去。
- **`b.lo` 跳 brk = 无符号减法下溢**；`b.vs` = 有符号溢出；`b.cs` = 无符号加法溢出。看分支前那条 `subs`/`adds` 的寄存器即知是哪个表达式。
- 不要用 `atos -l 0x100000000`（不处理 ASLR）；不要用 `lldb disassemble --name`（mangled 名常不匹配），用 `-s <链接地址>`。
- BSD awk 无 `strtonum`，地址运算改用 Python。

**已修的真实崩溃（build 39）**：`SystemMonitor.refresh()` 每 2s 定时器内，`totals.in - prevNet.in`（UInt64）下溢。底层 `if_data.ifi_ibytes` 与 `cpu_ticks` 都是 **32 位会回绕**；`readNetworkTotals()` 只累加 up 的非 lo0/非 P2P 接口，Wi-Fi 重连/网卡拔插/VPN 起停会让接口从总和消失 → 新值 < 旧值 → 陷阱。**`max(0, Double(a - b))` 完全无效**（下溢在减法阶段，早于 Double 转换）。修法：`delta(new,old) = new >= old ? new-old : 0`，编译成无分支 `csel`，零开销。网络/CPU/磁盘三处全改。**凡是「计数器差值」都要饱和减法。**

## 四、系统 API 易错点

**ScreenCaptureKit（build 23）**：枚举用 `SCShareableContent.getExcludingDesktopWindows(_:onScreenWindowsOnly:completionHandler:)`（不是 `.current{}`，那是 async getter）。`SCStreamConfiguration` 无 `scaleFactor`，直接设 `width`/`height` 像素；音频开关是 `capturesAudio`。`SCWindow` 只有 `frame`（point），无 width/height/scaleFactor/displayID —— 像素尺寸要 `frame.size × 所在屏 backingScaleFactor`。`SCStreamOutputType` 无 `.video`（是 `.screen`/`.audio`）；委托是 `stream(_:didOutputSampleBuffer:of:)`。`NSWindow` 子类不能声明存储属性名 `screen`（已继承）。`NSApp.activate(options:)` 歧义 → 用 `NSApplication.shared.activate(ignoringOtherApps:)`。需 `import UserNotifications`；build.sh 要链 ScreenCaptureKit/AVFoundation/CoreMedia/ImageIO/UniformTypeIdentifiers。

**CoreAudio 逐 App 音量 / process tap（build 31–33）**：`desc as CFDictionary` 是**非空**桥接，不能 `guard let`。子设备列表 selector 是 `kAudioAggregateDevicePropertyFullSubDeviceList`。`CFDictionary` 无下标，先转 `NSDictionary`。`AudioObjectAdd/RemovePropertyListenerBlock` 的 address 参数须 `var`。链路：`AudioHardwareCreateProcessTap` + `CATapDescription(stereoMixdownOfProcesses:)`（设 `uuid`、`muteBehavior = .mutedWhenTapped`）→ `AudioHardwareCreateAggregateDevice`（真实输出+tap）→ `AudioDeviceCreateIOProcIDWithBlock` 做增益；**需屏幕录制 TCC**。建完设备必须 `CFRunLoopRunInMode(.defaultMode, 0.01, false)` 轮询 `kAudioDevicePropertyDeviceIsAlive`。App 枚举走 `kAudioHardwarePropertyProcessObjectList`，XPC/helper 用 `NSWorkspace.runningApplications` 归并宿主。**RT 安全**：IO proc 在实时线程，状态用 `nonisolated(unsafe)` 单字标量，回调内禁分配/锁/日志/ObjC 消息。EQ 为 10 段 RBJ 峰值双二阶（转置 DF2 串联），系数主线程算；增益>100% 用代数饱和 `sign*(1+e/(1+e))` 防爆音；`Float(pow(10, Double/40))` 必须显式转 Float。

**DDC / DisplayServices（build 37）**：亮度走私有框架 `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`，`dlopen`+`dlsym` 取 `DisplayServicesSet/GetBrightness`；返回 `CGError`，判成功用 `.rawValue == 0`，不可 `Int(cgError)`。音量/输入源走 DDC-CI over I2C：`IOServiceMatching("IOI2CInterface")` → `IOServiceOpen` → `IOConnectCallStructMethod(conn, 0, ...)`，**不必**遍历 IOFramebuffer 子迭代器。`IOI2CRequest` 布局（pack(4), LP64, 124 字节）偏移手算：sendTransactionType@0, replyTransactionType@4, sendAddress@8(0x6E), replyAddress@12(0x6F), sendSubAddress@16(0x51), minReplyDelay(UInt64)@20, result@28, commFlags@32(=0x2), sendBytes@40, replyBytes@56, sendBuffer@68, replyBuffer@76。事务类型：combined=3、DDCciReply=2、none=0。**致命坑：指针字段绝不能指向局部数组**（悬垂崩溃），要把 send/reply 缓冲内联进同一段 `Data`，用 `raw.storeBytes(of: UInt(bitPattern: raw.baseAddress!)+offset, toByteOffset: 68, as: UInt.self)` 写真实地址。`Data` 扩展内写 `withUnsafeBytes(of:&v)` 会解析成实例方法，须写 `Swift.withUnsafeBytes`。`CGGetOnlineDisplayList` 的 count 参数须 `UInt32`。DDC 需真实外接显示器，本机只能编译验证。

## 五、功能与热键（全部 ⌃⌥ 基底，共 23 个功能）

| 模块 | id | 热键 | 行为 |
|---|---|---|---|
| 电源 | power | Q/D/E/T | 锁屏(SACLockScreenImmediate, login.framework) / 睡眠(pmset sleepnow) / 熄屏(pmset displaysleepnow) / 切深色(SLSSetAppearanceThemeLegacy) |
| 文字片段 | snippets | B | 面板选中→剪贴板+合成⌘V |
| 二维码 | qr | F | CIQRCodeGenerator，可复制/保存 |
| 屏幕取色 | colorpicker | G | NSColorSampler→#RRGGBB→剪贴板+通知 |
| 音量 | volume | X | CoreAudio 静音切换 |
| 截图标注 | screenshot | 5 | 主屏截屏→AnnotationEditor |

**新增功能三步（build 41 架构）**：① 加进 `AppDelegate.features` 数组（+ `defaultFeatures()` 同步，虽是死代码）；② `FeatureCatalog` 补 `FeatureMeta`（icon/title/description/category/分栏）→ 元数据唯一来源，驱动 `FeatureModuleCard`；③ `Configuration.defaultHotkeys()` + `label(for:)` 加键与中文标签 + `Key.swift` 补 VK。各模块设置页用统一的 `FeatureModuleCard`（`UI/Settings/FeatureModuleCard.swift`），开关走 `model.setFeatureEnabled`（内部 save() 同步 `registry.config`）。集中式「功能」列表页已废除，开关内嵌各模块卡。
**面板外观**：`win.appearance = Defaults[.appearanceMode].nsAppearance`（enum，别用 `== "dark"`）；卡片用纯 `RoundedRectangle`，不要空调用 `IadenteCard()`。
