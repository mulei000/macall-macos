import Cocoa
import CoreGraphics
import Foundation

/// 把当前窗口移动到上一台 / 下一台显示器，保持相对尺寸与位置。
///
/// 移植自 Macindow 的 DisplayMoveFeature（MIT）。
final class DisplayMoveFeature: Feature {
    let id = "displayMove"
    let title = IadenteL10n.t("跨屏移动", "Move Across Displays")
    let category = FeatureCategory.window

    private let bindings: [(action: String, configKey: String)] = [
        ("next", "display.next"),
        ("prev", "display.prev"),
    ]

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
            Log.error("辅助功能未授权，无法移动窗口 (action=\(action))")
            return
        }
        let dir: Int = (action == "next") ? 1 : -1
        move(dir: dir)
    }

    private func move(dir: Int) {
        guard let win = AX.focusedWindow(), let frame = AX.frame(of: win) else {
            Log.warning("无法获取当前窗口进行显示器移动")
            return
        }
        // `frame` 已在 CG 全局坐标（左上原点）。全程在该坐标系内计算。
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            Log.info("只有一台显示器，忽略移动请求")
            return
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let idx = screens.firstIndex(where: { NSScreen.cgFrame(of: $0).contains(center) }) else { return }
        let targetIdx = (idx + dir + screens.count) % screens.count
        let src = NSScreen.cgVisibleFrame(of: screens[idx])
        let dst = NSScreen.cgVisibleFrame(of: screens[targetIdx])

        let relX = (frame.minX - src.minX) / src.width
        let relY = (frame.minY - src.minY) / src.height
        let relW = frame.width / src.width
        let relH = frame.height / src.height

        let newRect = CGRect(
            x: dst.minX + relX * dst.width,
            y: dst.minY + relY * dst.height,
            width: relW * dst.width,
            height: relH * dst.height
        )
        AX.setFrame(win, newRect)
        Log.info("窗口已移动到显示器 \(targetIdx)")
    }

    func uninstall() {}
}
