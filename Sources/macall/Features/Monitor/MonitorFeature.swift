import AppKit
import Combine
import Foundation

/// 系统监控功能：拥有 `SystemMonitor`，把聚合快照接入菜单栏与仪表盘。
/// 对应 "Macindow + maconitor 合并" 中的 maconitor 一侧。
final class MonitorFeature: Feature {
    let id = "monitor"
    let title = IadenteL10n.t("系统监控", "System Monitor")
    let category = FeatureCategory.monitor
    let enabledByDefault = true

    let monitor = SystemMonitor()

    /// 快照变化时回调（AppDelegate 用来刷新菜单栏标题）。
    var onUpdate: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    func install(context: AppContext) {
        // 依据当前「监控模块是否隐藏 + 是否启用通知阈值」决定采样策略，
        // 避免隐藏监控时仍每 2s 全量采样（含能耗扫描）空耗 CPU。
        updateSamplingPolicy()
        // 首轮数据由 SystemMonitor.start 内立即读取；稍后通知刷新菜单栏标题。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.onUpdate?()
        }
        observePolicyChanges()
    }

    func uninstall() {
        monitor.stop()
        cancellables.removeAll()
    }

    func reload(config: Configuration) {
        updateSamplingPolicy()
    }

    /// 监控是否整体不可见：与 StatusBarManager.visibleModules 同口径——
    /// moduleOrder 中没有任何一个模块未被隐藏时，状态栏监控图标不显示。
    private func isMonitorHidden() -> Bool {
        let moduleOrder: [StatusBarModule] = Defaults[.statusBarModuleOrder]
        let hidden = Set(Defaults[.statusBarHiddenModules])
        return moduleOrder.filter { !hidden.contains($0) }.isEmpty
    }

    /// 监控模块在状态栏隐藏时按需调整采样策略，降低常驻占用：
    /// - 显示 → 正常 2s 采样（实时数据刚需）。
    /// - 隐藏 + 仍有任意通知阈值启用 → 降频到 10s，保留阈值通知能力。
    /// - 隐藏 + 无任何通知阈值 → 完全停止采样，省 CPU。
    private func updateSamplingPolicy() {
        let hidden = isMonitorHidden()
        let notificationsActive =
            !Defaults[.disableNotifications] &&
            (Defaults[.notifyCpuTempEnabled] || Defaults[.notifyPowerEnabled] ||
             Defaults[.notifyRamEnabled] || Defaults[.notifyStorageEnabled])
        if hidden {
            if notificationsActive {
                monitor.start(interval: 10)
            } else {
                monitor.stop()
            }
        } else {
            monitor.start()
        }
    }

    /// 监听影响采样策略的 Defaults 变化，动态 start / stop / 降频 monitor。
    private func observePolicyChanges() {
        let apply: () -> Void = { [weak self] in self?.updateSamplingPolicy() }
        Defaults.publisher(.statusBarModuleOrder).sink { _ in apply() }.store(in: &cancellables)
        Defaults.publisher(.statusBarHiddenModules).sink { _ in apply() }.store(in: &cancellables)
        Defaults.publisher(.disableNotifications).sink { _ in apply() }.store(in: &cancellables)
        Defaults.publisher(.notifyCpuTempEnabled).sink { _ in apply() }.store(in: &cancellables)
        Defaults.publisher(.notifyPowerEnabled).sink { _ in apply() }.store(in: &cancellables)
        Defaults.publisher(.notifyRamEnabled).sink { _ in apply() }.store(in: &cancellables)
        Defaults.publisher(.notifyStorageEnabled).sink { _ in apply() }.store(in: &cancellables)
    }

    func menuItems() -> [NSMenuItem]? {
        let s = monitor.snapshot
        let title = s.battery.isValid ? IadenteL10n.t("电池 \(s.battery.percentage)%", "Battery \(s.battery.percentage)%") : IadenteL10n.t("电池 —", "Battery —")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return [item]
    }
}
