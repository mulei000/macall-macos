import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 键盘驱动的分屏。每个动作根据屏幕可见区域（排除菜单栏 + Dock）计算目标
/// 矩形，再通过 Accessibility API 应用。
///
/// 移植自 Macindow 的 WindowSnapFeature（MIT），按 macall 的 Feature 协议接入。
final class WindowSnapFeature: Feature {
    let id = "windowSnap"
    var title: String { IadenteL10n.t("窗口分屏", "Window Snap") }
    let category = FeatureCategory.window

    private let bindings: [(action: String, configKey: String)] = [
        ("leftHalf", "snap.leftHalf"), ("rightHalf", "snap.rightHalf"),
        ("topHalf", "snap.topHalf"), ("bottomHalf", "snap.bottomHalf"),
        ("topLeft", "snap.topLeft"), ("topRight", "snap.topRight"),
        ("bottomLeft", "snap.bottomLeft"), ("bottomRight", "snap.bottomRight"),
        ("leftThird", "snap.leftThird"), ("rightThird", "snap.rightThird"),
        ("centerThird", "snap.centerThird"),
        ("leftTwoThirds", "snap.leftTwoThirds"), ("rightTwoThirds", "snap.rightTwoThirds"),
        ("maximize", "snap.maximize"),
        ("center", "snap.center"), ("restore", "snap.restore"),
    ]

    private var context: AppContext?
    private var lastWindow: AXUIElement?
    private var lastFrame: CGRect?

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

    func reload(config: Configuration) {
        self.context?.config = config
    }

    func handle(action: String) {
        // 辅助功能静默检测；状态在设置界面展示。
        guard Permissions.isAccessibilityWorking() else {
            Log.error("辅助功能未授权，无法操作窗口 (action=\(action))")
            return
        }

        guard let win = AX.focusedWindow() else {
            Log.warning("无法获取当前窗口 (action=\(action))，可能没有前台窗口")
            return
        }

        if action == "restore" {
            if let w = lastWindow, let f = lastFrame {
                AX.setFrame(w, f)
            }
            return
        }

        guard let kind = SnapKind(rawValue: action) else { return }
        let vf = AX.visibleFrameForWindow(win)
        let gap = CGFloat(context?.config.gap ?? 0)
        let target = SnapLayout.compute(kind: kind, visibleFrame: vf, gap: gap)

        if let prev = AX.frame(of: win), kind != .maximize {
            lastWindow = win
            lastFrame = prev
        }
        AX.setFrameSnapped(win, target: target, visibleFrame: vf)
        Log.info("分屏成功: \(action) -> \(target)")
    }

    func uninstall() {}
}
