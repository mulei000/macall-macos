import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation

/// Dock 图标反转（复刻 Windows 任务栏行为）：
/// 点击「已经是当前激活 App」的 Dock 图标 → 把它的所有窗口最小化（缩小）；
/// 再点一次 → 全部恢复。点击未激活的 App 则照常交给系统（激活 / 恢复）。
///
/// 这是 macall 早期被移除的 `dockToggle` 模块，按用户要求恢复。
/// 逻辑原样复用 Macindow 的 DockToggleFeature.swift（用户要求：Dock 相关功能
/// 完全复用 Macindow 代码，仅做 app 框架适配，不做视觉 / 逻辑改动）。
final class DockToggleFeature: Feature {
    let id = "dockToggle"
    let title = IadenteL10n.t("Dock 图标反转", "Dock Icon Reverse")
    let category: FeatureCategory = .window
    let enabledByDefault = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var enabled = true
    private var behavior: DockToggleBehavior = .minimize
    private var context: AppContext?

    /// 我们刚切换过某个 App 后，系统焦点状态（`app.isActive`）会滞后几百毫秒。
    /// 这段时间内的第二次点击会被误判为「App 仍在前台」而被再次消费（重新最小化，
    /// 或做一次被节流的激活），表现为「点了没反应，过会儿才行」。
    /// 因此冷却期内对同一个 App 的点击直接放行给系统（由系统负责恢复它）。
    private var lastTogglePID: pid_t = 0
    private var lastToggleTime = Date.distantPast
    private let toggleCooldown: TimeInterval = 0.7

    func install(context: AppContext) {
        self.context = context
        self.enabled = context.config.isFeatureEnabled(self.id, default: enabledByDefault)
        installTap()
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(UInt64(1) << UInt64(CGEventType.leftMouseDown.rawValue))
        let cb: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let f = Unmanaged<DockToggleFeature>.fromOpaque(userInfo).takeUnretainedValue()
            // 自愈：macOS 会静默禁用回调过慢的 tap，我们重新启用自己。
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = f.tap { CGEvent.tapEnable(tap: t, enable: f.enabled) }
                return Unmanaged.passRetained(event)
            }
            guard type == .leftMouseDown else { return Unmanaged.passRetained(event) }
            return f.handleMouseEvent(event)
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cb,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Log.error("[docktoggle] 无法创建鼠标监听（请确认辅助功能已授权，并在设置中点击「重新加载监听」）")
            return
        }
        self.tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: enabled)
        Log.info("[docktoggle] 已启动（enabled=\(enabled)）")
    }

    func reenable() {
        if tap == nil { installTap(); return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    func ensureTap() {
        if tap == nil {
            installTap()
        } else if let t = tap, !CGEvent.tapIsEnabled(tap: t) {
            CGEvent.tapEnable(tap: t, enable: enabled)
            Log.info("[docktoggle] 鼠标监听被系统禁用，已重新启用")
        }
    }

    /// 在事件 tap 内同步执行、只读决策。返回 nil 表示吞掉这次点击（我们接管），
    /// 返回 event 表示放行给系统。
    private func handleMouseEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard context?.config.enabled ?? true, enabled else { return Unmanaged.passRetained(event) }

        let cg = event.location // CG 全局坐标（左上原点）
        guard let dockRect = DockDetector.dockRect(), dockRect.contains(cg) else {
            return Unmanaged.passRetained(event)
        }
        guard let app = DockDetector.appIconAt(cgPoint: cg) else {
            return Unmanaged.passRetained(event)
        }
        // 绝不接管 macall 自己的 Dock 图标：自己的图标应该交给系统的
        // applicationShouldHandleReopen（打开 / 隐藏设置窗口）。否则会误把设置窗口最小化，
        // 表现为「点 Dock 闪一下就消失、唤不出主界面」。
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return Unmanaged.passRetained(event)
        }
        // 我们刚切换过的 App，系统焦点滞后；冷却期内直接放行给系统，由它负责恢复。
        if app.processIdentifier == lastTogglePID,
           Date().timeIntervalSince(lastToggleTime) < toggleCooldown {
            return Unmanaged.passRetained(event)
        }
        // 仅在点击的 App 确实处于激活态时才接管：最小化的 / 后台的 App 必须照常
        // 由系统恢复或带到前台，不能被我们误吞。
        guard app.isActive else {
            return Unmanaged.passRetained(event)
        }
        // App 已激活 → 我们接管这次点击：吞掉 + 切换（最小化全部）。
        lastTogglePID = app.processIdentifier
        lastToggleTime = Date()
        let target = app
        DispatchQueue.main.async { [weak self] in self?.toggle(app: target) }
        return nil
    }

    private func toggle(app: NSRunningApplication) {
        switch behavior {
        case .minimize:
            guard let windows = AX.windows(of: app), !windows.isEmpty else { return }
            let anyVisible = windows.contains { !AX.isMinimized($0) }
            // 有可见窗口 → 全部最小化；否则全部恢复。
            let minimize = anyVisible
            for w in windows {
                AX.setMinimized(w, minimize)
            }
            if !minimize {
                app.activate() // 恢复后带回焦点
            }
            Log.info("[docktoggle] \(app.localizedName ?? "?") -> \(minimize ? "最小化" : "恢复")")
        case .hideApp:
            if app.isHidden {
                app.activate()
                Log.info("[docktoggle] \(app.localizedName ?? "?") -> 恢复显示")
            } else {
                app.hide()
                Log.info("[docktoggle] \(app.localizedName ?? "?") -> 隐藏 App")
            }
        }
    }

    func reload(config: Configuration) {
        enabled = config.isFeatureEnabled(self.id, default: enabledByDefault)
        behavior = config.dockToggleBehavior
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    func uninstall() {
        // 彻底移除鼠标监听（不止禁用）：从 run loop 摘除源并使 mach port 失效，
        // 避免「关闭开关后 tap 仍挂在 run loop 上」的残留。重新开启时由 install/reenable 重建。
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        Log.info("[docktoggle] 已卸载：移除鼠标监听")
    }
}
