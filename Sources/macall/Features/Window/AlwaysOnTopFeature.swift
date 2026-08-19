import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UserNotifications

// MARK: - 窗口置顶（Always-on-Top）

/// 把任意 App 的窗口「钉」在其他窗口之上，再按一次取消。
///
/// ## 方案（参考 GitHub 上的 Topit）
///
/// 旧实现靠 `kAXRaiseAction` + 0.45s 看门狗反复去抢 WindowServer 的 z 序，
/// 天生要闪（掉下去→抬起的往复、Electron/Java 系自激成环、两窗口互压）。
///
/// 现在改用 **PinOverlay**（`PinOverlay.swift`）：用 ScreenCaptureKit 实时捕获目标窗口画面，
/// 画到我们自己进程的 `.floating` 覆盖层上，严丝合缝盖在原位。覆盖层是我们自己的窗口，
/// WindowServer 天然允许它浮在普通窗口之上，**一帧都不会掉下去，所以根本不闪**。
/// 交互靠「让位」：鼠标移入时激活真窗口并把覆盖层 alpha 降到 0（点击穿透），移开再恢复捕获。
///
/// 本类只负责「哪个窗口被钉了」的状态簿记与快捷键派发，所有捕获 / 绘制 / 跟随逻辑都在 PinOverlay。
///
/// ⚠️ 需要**屏幕录制**权限（捕获窗口画面）+ **辅助功能**权限（让位时抬升真窗口）。
final class AlwaysOnTopFeature: Feature {
    let id = "alwaysontop"
    let title = IadenteL10n.t("窗口置顶", "Always on Top")
    let category = FeatureCategory.window
    var enabledByDefault: Bool = true

    private var context: AppContext?

    /// 被钉住的窗口：CGWindowID → 覆盖层控制器。单窗口单 PinOverlay。
    private var pinned: [CGWindowID: PinOverlay] = [:]

    /// 供设置页显示「当前钉住了哪些窗口」。
    var pinnedDescriptions: [String] {
        pinned.values.map(\.appName).sorted()
    }
    var pinnedCount: Int { pinned.count }

    // MARK: - Feature

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[alwaysontop] 已安装：⌃⌥W 切换最前台窗口置顶（需屏幕录制 + 辅助功能权限）")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["alwaysontop.toggle"]?.toCombo()
            ?? Configuration.defaultHotkeys()["alwaysontop.toggle"]!.toCombo()
        context?.hotkeys.bind(
            featureId: id, action: "toggle", configKey: "alwaysontop.toggle", defaultCombo: combo)
    }

    func handle(action: String) {
        switch action {
        case "toggle": toggleFrontmost()
        case "unpinAll": unpinAll()
        default: break
        }
    }

    func reload(config: Configuration) { bindHotkey(using: config) }

    func uninstall() { unpinAll() }

    // MARK: - 核心

    private func toggleFrontmost() {
        Task { @MainActor in await self.performToggle() }
    }

    /// 在 main actor 上执行真正的切换逻辑。所有覆盖层状态都只在主线程访问，避免并发踩踏。
    @MainActor
    private func performToggle() async {
        // 让位时需要辅助功能权限去抬升真窗口。先预检，缺了直接引导授权。
        guard AXIsProcessTrusted() else {
            Log.warning("[alwaysontop] 未获辅助功能权限，无法置顶")
            let prompted = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            notify(prompted
                ? IadenteL10n.t("请在系统设置中授权「辅助功能」后重试",
                               "Grant Accessibility access in System Settings, then retry")
                : IadenteL10n.t("窗口置顶需要辅助功能权限",
                               "Always on Top needs Accessibility access"))
            return
        }

        // ① 先判定「要取消哪一个」。优先级：
        //    a) 最前台窗口（用户正对着它按快捷键）—— 正常置顶态；
        //    b) 光标正悬停其上的置顶覆盖层 —— 覆盖层可能是透明的（如窗口已最小化），
        //       此时最前台窗口早已不是它，但只要把光标移到窗口原位就能命中。
        // 没有这两条，最小化 / 切到别的 App 后的置顶窗口会永远取消不掉
        // （之前 minimize 直接 cancel 把这个问题盖住了，现在 keep-pin 后暴露出来）。
        if let app = NSWorkspace.shared.frontmostApplication,
           let win = AX.focusedWindow(),
           let wid = AX.cgWindowID(of: win),
           pinned[wid] != nil {
            unpin(wid: wid)
            return
        }
        if let wid = pinnedWidUnderCursor() {
            unpin(wid: wid)
            return
        }

        // ② 否则在最前台窗口上新建置顶。
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // 不处理本 App 自己的窗口（设置面板本来就在最前，钉住毫无意义）。
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        guard let win = AX.focusedWindow(), let wid = AX.cgWindowID(of: win) else {
            Log.info("[alwaysontop] 未找到最前台窗口（pid=\(app.processIdentifier)）")
            notify(IadenteL10n.t("未找到可置顶的窗口", "No window to pin"))
            return
        }

        // 兜底：理论上上面已拦截，这里再保险一次。
        if pinned[wid] != nil { unpin(wid: wid); return }

        // 未钉 → 新建覆盖层
        let name = app.localizedName ?? "App"
        guard let overlay = await PinOverlay.pin(
            windowID: wid,
            appName: name,
            ownerPID: app.processIdentifier,
            onClosed: { [weak self] closedWid in
                Task { @MainActor in self?.pinned.removeValue(forKey: closedWid) }
            }
        ) else {
            notify(IadenteL10n.t("置顶失败：请检查屏幕录制与辅助功能权限",
                                 "Pin failed: check Screen Recording & Accessibility access"))
            return
        }
        pinned[wid] = overlay
        Log.info("[alwaysontop] 置顶 wid=\(wid) (\(name))")
        notify(IadenteL10n.t("已置顶：\(name)", "Pinned on top: \(name)"))
    }

    @MainActor
    private func unpin(wid: CGWindowID) {
        guard let existing = pinned[wid] else { return }
        let name = existing.appName
        existing.close(reason: "用户取消")
        pinned.removeValue(forKey: wid)
        Log.info("[alwaysontop] 取消置顶 wid=\(wid) (\(name))")
        notify(IadenteL10n.t("已取消置顶：\(name)", "Unpinned: \(name)"))
    }

    /// 光标当前是否悬停在某个置顶覆盖层上（覆盖层可能透明，例如窗口已最小化）。
    @MainActor
    private func pinnedWidUnderCursor() -> CGWindowID? {
        let loc = NSEvent.mouseLocation
        for (wid, overlay) in pinned where overlay.currentFrame.contains(loc) {
            return wid
        }
        return nil
    }

    private func unpinAll() {
        Task { @MainActor in
            guard !self.pinned.isEmpty else { return }
            for (_, overlay) in self.pinned { overlay.close(reason: "全部取消") }
            self.pinned.removeAll()
            Log.info("[alwaysontop] 已取消全部置顶")
        }
    }

    private func notify(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = IadenteL10n.t("窗口置顶", "Always on Top")
        content.body = text
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
