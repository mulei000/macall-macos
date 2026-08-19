import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 权限检测辅助。窗口操作依赖「辅助功能」，全局快捷键依赖「输入监控」。
/// 当前实现不主动弹系统对话框；状态在设置界面内检测并显示，用户点击按钮跳转系统设置。
///
/// 移植自 Macindow（MIT），字符串适配 macall。
enum Permissions {
    // MARK: - State reported by the event taps

    /// Set to true once a session-wide CGEventTap was created successfully.
    static var inputMonitoringGranted: Bool = false

    // MARK: - Accessibility

    /// Whether the app is currently trusted for Accessibility access (标志位).
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// **Operational** accessibility check: 真正尝试用 AX 查询前台应用的窗口列表。
    /// 这是决定性测试 —— `AXIsProcessTrusted()` 有时会在重启后 TCC 缓存过期时
    /// 仍返回 true，但 AX 调用实际失败。
    static func isAccessibilityWorking() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        return err == .success
    }

    /// Prompt the system dialog if not yet trusted. 一般不主动调用。
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Input Monitoring

    /// Probes Input Monitoring by attempting a throwaway listen-only tap.
    static func isInputMonitoringTrusted() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let cb: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passRetained(event) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: cb,
            userInfo: nil
        ) else {
            inputMonitoringGranted = false
            return false
        }
        CFMachPortInvalidate(tap)
        inputMonitoringGranted = true
        return true
    }

    // MARK: - Screen Recording

    /// Whether Screen Recording is currently authorized. Best-effort: uses the
    /// public `CGPreflightScreenCaptureAccess()` which is reliable once TCC has
    /// settled, but returns false briefly after launch even when granted — so
    /// callers should never *gate* capture on this; attempt capture and fall back.
    /// 移植自 Macindow。
    static func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompt the system Screen Recording dialog.
    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Settings shortcuts

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// 麦克风：输入监听需要。一旦被用户拒绝，系统不会再弹授权窗，只能引导手动开。
    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // MARK: - Drag-to-authorize helper

    /// 校验拖入的 app 是否就是 macall 本身（按 bundle identifier）。
    ///
    /// macOS 的 TCC 机制**不允许**第三方 app 自行把自己加入「辅助功能 / 屏幕录制」
    /// 白名单——开关必须由用户在「系统设置」里手动翻转。因此"拖拽授权"能做到的是：
    /// 确认用户拖进来的是 macall 本尊，然后自动跳转到对应的系统设置隐私面板，
    /// 由用户在面板里把开关打开（若列表里还没有 macall，点「+」时面板已就位）。
    static func isMacallBundle(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }
        guard let bundle = Bundle(url: url) else { return false }
        return bundle.bundleIdentifier == "com.macall.app"
    }

    // MARK: - Diagnostic summary

    static func diagnosticReport() -> String {
        var lines: [String] = []
        let axFlag = isAccessibilityTrusted()
        let axWork = isAccessibilityWorking()
        // 直接用 HotkeyManager 维护的授权标志，诊断阶段不再创建事件监听 tap，
        // 避免反复建/销 tap 带来的脆弱性与 TCC 弹窗。
        let input = inputMonitoringGranted

        lines.append(IadenteL10n.t("=== macall 权限诊断 ===", "=== macall Permission Diagnostic ==="))
        lines.append(IadenteL10n.t("辅助功能(标志位): \(axFlag ? "✅" : "❌")", "Accessibility (flag): \(axFlag ? "✅" : "❌")"))
        lines.append(IadenteL10n.t("辅助功能(实测):   \(axWork ? "✅" : "❌")", "Accessibility (actual):   \(axWork ? "✅" : "❌")"))
        lines.append(IadenteL10n.t("输入监控:         \(input ? "✅" : "❌")", "Input Monitoring:         \(input ? "✅" : "❌")"))
        let screen = isScreenRecordingTrusted()
        lines.append(IadenteL10n.t("屏幕录制:         \(screen ? "✅" : "❌")", "Screen Recording:         \(screen ? "✅" : "❌")"))

        if !axWork {
            lines.append("")
            lines.append(IadenteL10n.t("⚠️ 辅助功能未生效，窗口操作（分屏/隐藏/移动）全部无法工作。", "⚠️ Accessibility not working; window ops (snap/hide/move) are all disabled."))
            lines.append(IadenteL10n.t("  1. 打开「系统设置 › 隐私与安全性 › 辅助功能」", "  1. Open System Settings › Privacy & Security › Accessibility"))
            lines.append(IadenteL10n.t("  2. 确认 macall 开关为「开」", "  2. Make sure macall\'s switch is ON"))
            lines.append(IadenteL10n.t("  3. 若列表中没有 macall，点「+」手动添加", "  3. If macall isn\'t listed, click + to add it manually"))
            lines.append(IadenteL10n.t("  4. 完全退出 macall（⌘Q）后重新打开", "  4. Fully quit macall (⌘Q) then reopen"))
        }
        if !input {
            lines.append("")
            lines.append(IadenteL10n.t("⚠️ 输入监控未授权，全局快捷键无法监听。", "⚠️ Input Monitoring not authorized; global shortcuts can\'t be captured."))
            lines.append(IadenteL10n.t("请在「系统设置 › 隐私与安全性 › 输入监控」中开启 macall。", "Enable macall in System Settings › Privacy & Security › Input Monitoring."))
        }
        if !screen {
            lines.append("")
            lines.append(IadenteL10n.t("⚠️ 屏幕录制未授权，Dock 预览缩略图无法捕获窗口画面。", "⚠️ Screen Recording not authorized; Dock preview thumbnails can\'t capture windows."))
            lines.append(IadenteL10n.t("请在「系统设置 › 隐私与安全性 › 屏幕录制」中开启 macall。", "Enable macall in System Settings › Privacy & Security › Screen Recording."))
        }

        return lines.joined(separator: "\n")
    }
}
