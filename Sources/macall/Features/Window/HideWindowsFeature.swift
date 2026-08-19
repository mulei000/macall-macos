import Cocoa
import CoreGraphics
import Foundation

/// 通过 AX API 最小化窗口实现「隐藏其他 / 隐藏全部 / 显示全部」。
///
/// **v0.5.0 build 42 起，「显示桌面」拆成两个独立子功能**：
/// 原来 `hide.all` 是一个会来回切换的开关键（按一次隐藏、再按一次恢复），
/// 用户无法只隐藏或只恢复，而且按错一次状态就反了。现在：
/// - `hide.all` —— 只负责隐藏全部窗口（露出桌面），重复按只会把新开的窗口一并收掉；
/// - `show.all` —— 只负责把 macall 隐藏过的窗口还原（不会误还原用户自己最小化的窗口）。
///
/// 移植自 Macindow 的 HideWindowsFeature（MIT），隐藏/恢复的记账逻辑为 macall 新增。
final class HideWindowsFeature: Feature {
    let id = "hideWindows"
    var title: String { IadenteL10n.t("隐藏窗口", "Hide Windows") }
    let category = FeatureCategory.window

    private let bindings: [(action: String, configKey: String)] = [
        ("others", "hide.others"),
        ("current", "hide.current"),
        ("all", "hide.all"),
        ("showAll", "show.all"),
    ]

    /// 记录本次「显示桌面」操作隐藏掉的窗口，便于再次按下时精准还原。
    private var hiddenByUs: [AXUIElement] = []

    private var context: AppContext?

    func install(context: AppContext) {
        self.context = context
        let defaults = Configuration.defaultHotkeys()
        for b in bindings {
            context.hotkeys.bind(
                featureId: id, action: b.action, configKey: b.configKey,
                defaultCombo: defaults[b.configKey]!.toCombo()
            )
        }
    }

    func handle(action: String) {
        guard Permissions.isAccessibilityWorking() else {
            Log.error("辅助功能未授权，无法缩小窗口 (action=\(action))")
            showAccessibilityAlert()
            return
        }
        switch action {
        case "others": hideOthers()
        case "current": hideCurrent()
        case "all": hideAll()
        case "showAll": restoreAll()
        default: break
        }
    }

    private func hideOthers() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier != front.bundleIdentifier {
            minimizeWindows(of: app)
        }
    }

    /// 隐藏当前最前台窗口（仅最小化单个焦点窗口，不累及其他窗口）。
    private func hideCurrent() {
        guard let win = AX.focusedWindow(), !AX.isMinimized(win) else { return }
        AX.setMinimized(win, true)
        Log.info("[hideWindows] 隐藏当前窗口")
    }

    /// 隐藏全部窗口（露出桌面）。可反复按：新开的窗口会追加进待恢复清单，
    /// 已经在清单里的不会重复记账，因此不会把「显示全部」搞乱。
    private func hideAll() {
        for app in NSWorkspace.shared.runningApplications {
            guard let windows = AX.windows(of: app) else { continue }
            for w in windows where !AX.isMinimized(w) {
                AX.setMinimized(w, true)
                if !hiddenByUs.contains(where: { CFEqual($0, w) }) {
                    hiddenByUs.append(w)
                }
            }
        }
        Log.info("[hideWindows] 隐藏全部，共记账 \(hiddenByUs.count) 个窗口")
    }

    /// 还原此前由「隐藏全部」收起的窗口（跳过用户原本就最小化的、或已失效的）。
    private func restoreAll() {
        var restored = 0
        for w in hiddenByUs where AX.isMinimized(w) {
            AX.setMinimized(w, false)
            restored += 1
        }
        hiddenByUs.removeAll()
        Log.info("[hideWindows] 显示全部，已还原 \(restored) 个窗口")
    }

    private func minimizeWindows(of app: NSRunningApplication) {
        guard let windows = AX.windows(of: app) else { return }
        for w in windows where !AX.isMinimized(w) {
            AX.setMinimized(w, true)
        }
    }

    func uninstall() {}

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = IadenteL10n.t("需要辅助功能权限", "Accessibility permission required")
            alert.informativeText =
                IadenteL10n.t("缩小窗口需要「辅助功能」权限。\n\n", "Shrinking windows requires the Accessibility permission.\n\n") +
                IadenteL10n.t("请到「系统设置 › 隐私与安全性 › 辅助功能」中开启 macall，然后退出重开。", "Enable macall in System Settings › Privacy & Security › Accessibility, then quit and reopen.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: IadenteL10n.t("打开系统设置", "Open System Settings"))
            alert.addButton(withTitle: IadenteL10n.t("稍后再说", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openAccessibilitySettings()
            }
        }
    }
}
