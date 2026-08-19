import AppKit
import Foundation
import Observation

/// 数据视图模型：照搬 macometer 的 MenuViewModel 公开属性与「实时更新机制」，
/// 仅把底层数据源从 macometer 的 BatteryService/SystemStatusProvider 替换为
/// macall 的 SystemMonitor。
///
/// 关键纪律（来自 macometer，已验证可用）：用 `withObservationTracking` 订阅
/// SystemMonitor 的 `@Observable` 快照，快照一变更就重算本模型的格式化属性，
/// 由 `@Observable` 自动驱动 SwiftUI（状态栏 NSHostingView 与弹窗）重绘。
/// 这比「独立 Timer 轮询拉取」更稳——后者在某些运行环境下计时器回调不触发，
/// 会导致状态栏看起来「不更新」。
@MainActor
@Observable
final class MenuViewModel {
    // MARK: - 电池 / 电源文案

    var batteryPercentageText: String = "0%"
    var powerSourceText: String = IadenteL10n.t("电池")
    var timeRemainingText: String = IadenteL10n.t("正在估算…")
    var uptimeText: String = IadenteL10n.t("0 分钟", "0 min")
    var batteryModeText: String = IadenteL10n.t("未知")
    var batteryTemperatureText: String = "—"
    var externalInputText: String = "0V @ 0A"
    var internalInputText: String = "0V @ 0A"
    var cycleCountText: String = "0"
    var batteryHealthText: String = "100%"

    var displayPercentage: Int = 0
    var chargingMode: ChargingMode = .discharging
    var batteryPower: Double = 0
    var adapterPower: Double = 0
    var systemPower: Double = 0
    var powerSource: PowerSource = .battery
    var isCharging: Bool = false
    var isLowPowerModeEnabled: Bool = false
    var topEnergyApps: [AppEnergyUsageSnapshot] = []
    var hasEnergyUsageSample: Bool = false

    // MARK: - 系统状态模块（内存/磁盘/CPU温度/风扇/网速/CPU占用）

    var memoryUsedGB: Double = 0
    var memoryTotalGB: Double = 0
    var diskFreeGB: Double = 0
    var diskTotalGB: Double = 0
    var cpuUsagePercent: Double = -1
    var networkUpMBps: Double = -1
    var networkDownMBps: Double = -1
    var cpuTemperatureC: Double = -1
    var fanRPM: Double = -1

    var adapterConnected: Bool = false

    // MARK: - 状态栏充电指示迟滞（hysteresis）

    private var pendingChargingMode: ChargingMode?
    private var chargingModeSettleAt: Date?
    private let chargingModeSettleInterval: TimeInterval = 3

    // MARK: - 内部

    private let monitor: SystemMonitor
    private var bootTimestamp: Date?

    private var snapshotObservation: Task<Void, Never>?
    private var uptimeTask: Task<Void, Never>?

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        let uptime = ProcessInfo.processInfo.systemUptime
        self.bootTimestamp = uptime > 0 ? Date(timeIntervalSinceNow: -uptime) : nil
        startObservingSnapshot()
        startUptimeTimer()
        // 首屏立刻出一帧，避免启动后短暂空白。
        DispatchQueue.main.async { [weak self] in
            self?.refreshNow()
        }
    }

    // MARK: - 实时更新机制（照搬 macometer 的 withObservationTracking 循环）

    /// 订阅 SystemMonitor 的快照：快照一旦变更（SystemMonitor 每 2 秒刷新一次），
    /// 就重算本模型的格式化属性，从而驱动状态栏与弹窗实时刷新。
    private func startObservingSnapshot() {
        guard snapshotObservation == nil else { return }
        snapshotObservation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.refreshNow()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.monitor.snapshot
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    private func startUptimeTimer() {
        guard uptimeTask == nil else { return }
        uptimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.updateUptimeText()
            }
        }
    }

    // MARK: - 对外方法（与 macometer 同名同签名，供视图调用）

    func refresh() {
        // 立刻强制采集一帧新数据（macometer 的同名方法即强制一次轮询）。
        monitor.refresh()
        refreshNow()
    }

    func menuWillOpen() {
        refresh()
    }

    func menuDidClose() {
        // macometer 在此停止 uptime 采样计时器；本实现采用持续轮询，无需停。
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 数据刷新

    private func refreshNow() {
        let s = monitor.snapshot
        let b = s.battery
        let onAC = b.onACPower
        let charging = b.isCharging

        let pct = b.percentage >= 0 ? b.percentage : 0
        displayPercentage = pct
        batteryPercentageText = "\(pct)%"

        let derived: PowerSource = onAC ? .acAdapter : .battery
        powerSource = derived
        switch derived {
        case .battery: powerSourceText = IadenteL10n.t("电池")
        case .acAdapter: powerSourceText = IadenteL10n.t("电源适配器")
        case .both: powerSourceText = IadenteL10n.t("电池与电源适配器")
        }

        let targetMode: ChargingMode = onAC ? (charging ? .charging : .pluggedIn) : .discharging
        switch targetMode {
        case .charging: batteryModeText = IadenteL10n.t("正在充电")
        case .pluggedIn: batteryModeText = IadenteL10n.t("已接通电源（未充电）")
        case .discharging: batteryModeText = IadenteL10n.t("正在使用电池")
        }

        // 状态栏充电指示的迟滞：仅在目标状态稳定持续后才提交，避免瞬时抖动闪烁。
        if targetMode == chargingMode {
            pendingChargingMode = nil
            chargingModeSettleAt = nil
        } else if let pending = pendingChargingMode, pending == targetMode {
            if let at = chargingModeSettleAt,
               Date().timeIntervalSince(at) >= chargingModeSettleInterval {
                chargingMode = targetMode
                pendingChargingMode = nil
                chargingModeSettleAt = nil
            }
        } else {
            pendingChargingMode = targetMode
            chargingModeSettleAt = Date()
        }

        // 剩余 / 充满时间
        if !onAC, b.timeToEmptyMinutes > 0 {
            timeRemainingText = formatTimeRemaining(minutes: b.timeToEmptyMinutes)
        } else if onAC, b.timeToFullMinutes > 0 {
            timeRemainingText = formatTimeRemaining(minutes: b.timeToFullMinutes)
        } else if onAC, !charging {
            timeRemainingText = IadenteL10n.t("未在充电")
        } else {
            timeRemainingText = IadenteL10n.t("正在估算…")
        }

        // 电池健康深度（maconitor 风格）：循环次数 / 健康度。
        // 注：iOS/macOS 电池温度在 ioreg 中单位不统一、易误读，故本版不显示电池温度，
        // 保留 `batteryTemperatureText` 为「—」以免展示错误数值。
        cycleCountText = b.cycleCount > 0 ? "\(b.cycleCount)" : "—"
        batteryHealthText = b.healthPercent > 0 ? "\(b.healthPercent)%" : "—"

        // SMC 派生指标：直接复用 macometer 的采集结果（温度/风扇/功率），
        // 读取失败时为 nil，对应字段保持「—」/ 0 的自然空值。
        cpuTemperatureC = s.cpuTempC ?? -1
        fanRPM = s.fanRPM ?? -1
        batteryPower = s.batteryPower ?? 0
        adapterPower = s.adapterPower ?? 0
        // 系统功率 = 适配器功率 − 电池功率（放电时电池功率为负，结果自然为正）。
        systemPower = adapterPower - batteryPower

        // 实时耗电 App：照搬 macometer，已采样即标记。
        topEnergyApps = s.topEnergyApps
        hasEnergyUsageSample = true

        isCharging = charging
        adapterConnected = onAC
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        // 系统状态（macall 已有：CPU / 内存 / 磁盘 / 网速）
        cpuUsagePercent = s.cpu.isValid ? s.cpu.active : -1
        memoryUsedGB = Double(s.memory.usedBytes) / 1_000_000_000
        memoryTotalGB = Double(s.memory.totalBytes) / 1_000_000_000
        diskFreeGB = Double(s.disk.freeBytes) / 1_000_000_000
        diskTotalGB = Double(s.disk.totalBytes) / 1_000_000_000
        networkUpMBps = s.network.outBytesPerSec / 1_000_000
        networkDownMBps = s.network.inBytesPerSec / 1_000_000

        updateUptimeText()
    }

    private func updateUptimeText() {
        guard let boot = bootTimestamp else {
            uptimeText = IadenteL10n.t("未知")
            return
        }

        let totalMinutes = max(0, Int(Date().timeIntervalSince(boot) / 60))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        var components: [String] = []
        if days > 0 {
            components.append(IadenteL10n.t("\(days) 天", "\(days)d"))
        }
        if hours > 0 {
            components.append(IadenteL10n.t("\(hours) 小时", "\(hours)h"))
        }
        if minutes > 0 || components.isEmpty {
            components.append(IadenteL10n.t("\(minutes) 分钟", "\(minutes)m"))
        }
        uptimeText = components.prefix(2).joined(separator: " ")
    }

    private func formatTimeRemaining(minutes: Int) -> String {
        if minutes < 0 {
            return ""
        }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 {
            return IadenteL10n.t("\(mins) 分钟", "\(mins) min")
        }
        return IadenteL10n.t(
            "\(hours) 小时 \(mins) 分钟",
            "\(hours) hr \(mins) min"
        )
    }

    deinit {
        MainActor.assumeIsolated {
            snapshotObservation?.cancel()
            uptimeTask?.cancel()
        }
    }
}
