import AppKit
import Foundation

// MARK: - 崩溃记录

// 崩溃处理器在进入 NSApplication 之前就安装，连启动早期的崩溃也能捕获。
//
// 历史坑（build 39 修）：这里原本还有一套独立的 `installCrashReporter()` 实现，
// 与 `Core/CrashReporter.swift` 并存，两者写到**不同目录**
// （~/Library/Logs/macall/crash.log 与 ~/Library/Application Support/macall/Crashes/），
// 且后安装的会覆盖先安装的信号处理器，导致「日志到底在哪」难以说清。
// 现已统一到 CrashReporter 单例，只保留一个落盘位置。
CrashReporter.shared.install()

// 菜单栏常驻代理应用（LSUIElement=true，见 Resources/Info.plist）。
// 整个启动过程在 MainActor 上进行。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
