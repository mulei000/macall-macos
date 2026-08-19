import Foundation
import Observation

/// 系统监控器：聚合电池 / CPU / 内存 / 磁盘 / 网络 以及 SMC 派生指标（温度 / 风扇 / 功率）。
/// 电池 / CPU / 内存 / 磁盘 / 网络 通过用户态系统 API 读取（host_statistics / sysctl /
/// statfs / getifaddrs / IOKit），无需特权 Helper。SMC 则由 vendored SMCKit 经 IOKit
/// 直连 AppleSMC 读取（同样无需特权 Helper），与 macometer 的公式完全一致；风扇在无风扇
/// 机型返回 nil 并优雅降级为「—」。
///
/// 这是把自有项目 maconitor 的监控能力并入 macall 的完整实现：
/// - 电池沿用 maconitor 已验证的 IOKit 写法；
/// - CPU/内存/磁盘/网络为无特权补充，让菜单栏仪表盘立刻变实用；
/// - SMC 温度 / 风扇 / 功率现已直连可读（见 SMCReader / SMCSensors / SMCAdapter / SMCBattery）。
///
/// 轮询用主线程 RunLoop 的 Timer（菜单栏代理本就在主线程），避免跨 actor 隔离问题。
@Observable
final class SystemMonitor {
    /// 固定轮询间隔：2 秒。在「足够实时」与「足够低耗」之间取平衡，
    /// 不再提供用户可调刷新频率，避免设置复杂化与状态栏迟滞。
    static let defaultInterval: Double = 2

    private(set) var snapshot = SystemSnapshot()
    private var timer: Timer?
    private var interval: Double = SystemMonitor.defaultInterval

    // 计算速率/占比所需的上一轮原始值
    private var prevCPU: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) = (0, 0, 0, 0)
    private var prevNet: (in: UInt64, out: UInt64) = (0, 0)
    private var prevNetTime: TimeInterval = 0

    /// 开始按固定间隔轮询。重复调用会重启轮询。
    /// 传入 nil 时使用系统默认间隔（2 秒）。
    func start(interval: Double? = nil) {
        stop()
        self.interval = max(1, interval ?? SystemMonitor.defaultInterval)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 无符号差值：新值小于旧值时返回 0，而不是让 `UInt64` 减法下溢。
    ///
    /// 这是 build 38 之前 SIGTRAP 崩溃的根因所在。两个采样源的原始计数器都是
    /// **32 位**、会自然回绕，且总量可能凭空变小：
    /// - `if_data.ifi_ibytes/ifi_obytes` 是 `UInt32`，单网卡累计流量满 4 GiB 即归零；
    ///   另外 `readNetworkTotals()` 只累加「已 up 的非 lo0 非 P2P」接口，Wi-Fi 重连 /
    ///   网卡拔插 / VPN 起停都会让某个接口从求和里消失，总量瞬间下跌。
    /// - `host_cpu_load_info.cpu_ticks` 是 `natural_t`（`UInt32`），按 100 Hz × 核数
    ///   累加，十核机约 50 天回绕一次。
    ///
    /// 原写法 `max(0, Double(new - old))` 完全无效——下溢发生在 `UInt64` 减法阶段，
    /// 早于 `Double` 转换，Swift 直接抛运行时陷阱（EXC_BREAKPOINT / SIGTRAP）。
    @inline(__always)
    private static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        new >= old ? new - old : 0
    }

    /// 同步读取并刷新所有指标。
    func refresh() {
        var s = SystemSnapshot()

        // 电池
        s.battery = MonitorModels.readBattery()

        // CPU（按两次采样的差值计算占比）
        if let ticks = MonitorModels.readCPUTicks() {
            // `&+` 环绕加法：四项之和理论上不会越界，但显式声明「不因求和陷阱」。
            let total = ticks.user &+ ticks.system &+ ticks.idle &+ ticks.nice
            let prevTotal = prevCPU.user &+ prevCPU.system &+ prevCPU.idle &+ prevCPU.nice
            // tick 计数器回绕时 total 会小于 prevTotal，此时整轮跳过（仅更新基准）。
            if prevTotal > 0, total > prevTotal {
                let dTotal = Double(total - prevTotal)
                let dUser = Double(Self.delta(ticks.user, prevCPU.user))
                let dSys = Double(Self.delta(ticks.system, prevCPU.system))
                let dIdle = Double(Self.delta(ticks.idle, prevCPU.idle))
                s.cpu.user = max(0, dUser / dTotal * 100)
                s.cpu.system = max(0, dSys / dTotal * 100)
                s.cpu.idle = max(0, dIdle / dTotal * 100)
            }
            prevCPU = ticks
        }

        // 内存 / 磁盘（绝对量，直接读取）
        s.memory = MonitorModels.readMemory()
        s.disk = MonitorModels.readDisk()

        // 网络（按时间差计算速率）
        let now = Date.now.timeIntervalSince1970
        let totals = MonitorModels.readNetworkTotals()
        if prevNetTime > 0, now > prevNetTime {
            let dt = max(0.001, now - prevNetTime)
            s.network.inBytesPerSec = Double(Self.delta(totals.in, prevNet.in)) / dt
            s.network.outBytesPerSec = Double(Self.delta(totals.out, prevNet.out)) / dt
        }
        s.network.totalInBytes = totals.in
        s.network.totalOutBytes = totals.out
        prevNet = totals
        prevNetTime = now

        // SMC 派生指标（CPU 温度 / 风扇 / 功率）。读取失败时为 nil，由上层降级显示。
        let smc = SMCReader.sample()
        s.cpuTempC = smc.cpuTempC
        s.fanRPM = smc.fanRPM
        s.batteryPower = smc.batteryPower
        s.adapterPower = smc.adapterPower

        // 实时耗电 App 列表（topEnergyApps）由后台线程异步读取（见 fetchEnergyApps），
        // 避免每 2s 轮询时主线程被 /bin/ps 的 waitUntilExit 阻塞。
        // 这里先不上该字段，后台结果回来后立即合并进 snapshot。

        if !didLogSMC {
            didLogSMC = true
            if SMCReader.isAvailable {
                Log.info("[monitor] SMC 连接成功，温度/风扇/功率将实时读取")
            } else {
                Log.warning("[monitor] SMC 连接不可用（可能被沙箱/权限拦截），温度/风扇/功率将显示「—」")
            }
        }

        // 系统功率 = 适配器功率 − 电池功率（与 macometer 一致，放电时为负）。
        let systemPower = (smc.adapterPower ?? 0) - (smc.batteryPower ?? 0)

        // 带上上一轮的耗电 App 列表：本轮回填前若先发布空数组，能量卡片会在「无数据占位」
        // 与「3 行数据」之间每 2s 跳变一次，表现为整卡闪烁。带过来后后台 fetchEnergyApps()
        // 会用最新结果原地覆盖（build 77 已把该读取移出主线程），既消除闪烁又保留性能优化。
        s.topEnergyApps = snapshot.topEnergyApps

        snapshot = s
        fetchEnergyApps()

        Task { @MainActor in
            NotificationService.shared.evaluate(
                cpuTempC: smc.cpuTempC ?? -1,
                systemPower: systemPower,
                ramPercent: s.memory.usedPercent,
                storagePercent: s.disk.usedPercent
            )
        }
    }

    private var didLogSMC = false

    /// 后台读取实时耗电 App 排行。`AppEnergyService.readTopApps` 内部会 `waitUntilExit()` 一个
    /// `/bin/ps` 子进程，约几十~上百毫秒，若放在主线程每 2s 轮询里会周期性卡顿菜单栏刷新。
    /// 这里放到 `.utility` 后台线程计算，结果回主线程合并进 `snapshot.topEnergyApps`，
    /// 数据更新只比其它指标晚一拍（同一次轮询内补齐），对 UI / 通知无影响。
    private func fetchEnergyApps() {
        Task.detached(priority: .utility) { [weak self] in
            let apps = AppEnergyService.readTopApps(limit: 6)
            Task { @MainActor in
                guard let self else { return }
                var s = self.snapshot
                s.topEnergyApps = apps
                self.snapshot = s
            }
        }
    }
}
