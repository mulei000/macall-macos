import AppKit
import Foundation

// MARK: - 电源与外观快捷动作

/// 锁屏 / 系统睡眠 / 熄屏 / 切换深色模式。
///
/// - 熄屏：`pmset displaysleepnow`
/// - 系统睡眠：`pmset sleepnow`
/// - 锁屏：`SACLockScreenImmediate()`，失败才退回 `CGSession -suspend`
/// - 切换深色模式：`SLSSetAppearanceThemeLegacy`，失败才退回 System Events
///
/// 后两项原先只有 shell / AppleScript 实现，实测都不可靠：
/// `CGSession -suspend` 是**快速用户切换**而非锁屏（单账户机型会立刻弹回），
/// AppleScript 走 System Events 需要「自动化」授权，未授权时静默失败。
/// 现在优先调用系统自身用的私有入口，见 `PrivateAPI.swift` 第 4 节。
///
/// 这些动作都不依赖辅助功能权限（与窗口类动作不同），但锁屏/睡眠属于
/// 会改变系统状态的动作，仅由用户主动按快捷键触发，绝不自动执行。
final class PowerActionsFeature: Feature {
    let id = "power"
    let title = IadenteL10n.t("电源与外观", "Power & Appearance")
    let category = FeatureCategory.system
    var enabledByDefault: Bool = true

    private var context: AppContext?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[power] 已安装：⌃⌥E 熄屏 / ⌃⌥D 睡眠 / ⌃⌥Q 锁屏 / ⌃⌥T 切换深色模式")
    }

    private func bindHotkey(using config: Configuration) {
        let defaults = Configuration.defaultHotkeys()
        let bindOne: (String) -> Void = { key in
            let combo = config.hotkeys[key]?.toCombo() ?? defaults[key]!.toCombo()
            self.context?.hotkeys.bind(
                featureId: self.id, action: key, configKey: key, defaultCombo: combo)
        }
        ["power.displaySleep", "power.sleep", "power.lock", "power.toggleDark"].forEach(bindOne)
    }

    func handle(action: String) {
        // 不在主线程执行 shell/AppleScript，避免偶发卡顿。
        DispatchQueue.global(qos: .userInitiated).async {
            switch action {
            case "power.displaySleep": self.runCommand("/usr/bin/pmset", ["displaysleepnow"])
            case "power.sleep":       self.runCommand("/usr/bin/pmset", ["sleepnow"])
            case "power.lock":        self.lockScreen()
            case "power.toggleDark":  self.toggleDarkMode()
            default: break
            }
        }
    }

    func reload(config: Configuration) {
        bindHotkey(using: config)
    }

    func uninstall() {
        Log.info("[power] 已卸载")
    }

    // MARK: - 执行

    private func runCommand(_ launchPath: String, _ args: [String]) {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = args
        // 静默输出，避免子进程 stderr 干扰。
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            Log.warning("[power] 命令执行失败 \(launchPath) \(args): \(error)")
        }
    }

    /// 优先用系统自身的锁屏入口；只有符号缺失时才退回快速用户切换。
    private func lockScreen() {
        if lockScreenImmediately() { return }
        Log.warning("[power] SACLockScreenImmediate 不可用，退回 CGSession -suspend")
        runCommand(
            "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
            ["-suspend"])
    }

    private func toggleDarkMode() {
        // WindowServer 直调：无需自动化授权，立即生效。
        if SystemAppearance.toggle() { return }
        Log.warning("[power] SLSSetAppearanceThemeLegacy 不可用，退回 AppleScript")
        toggleDarkModeViaAppleScript()
    }

    private func toggleDarkModeViaAppleScript() {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
            end tell
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error {
            Log.warning("[power] 切换深色模式失败: \(error)")
        }
    }
}
