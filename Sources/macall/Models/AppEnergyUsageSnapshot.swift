import Foundation

/// 与 macometer DashboardPopoverView 的 `EnergyAppRow` 对齐的结构。
/// 直接照搬 macometer 的 `AppEnergyUsageSnapshot`（bundlePath / name / cpuUsage / pids），
/// 仅把类型名统一到 macall 的模块下。cpuUsage 为实时 CPU 活动占比（%）。
struct AppEnergyUsageSnapshot: Identifiable, Equatable, Sendable {
    let bundlePath: String
    let name: String
    let cpuUsage: Double
    let pids: [pid_t]

    var id: String { bundlePath }
}
