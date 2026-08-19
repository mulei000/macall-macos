import Foundation

/// 与 macometer 仪表盘「设置详情」跳转对应的标签页标识。
/// DashboardPopoverView 通过 `onOpenSettings(SettingsTab)` 把用户带到对应设置页。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case advanced
    case about
    case audio
    case tools

    var id: String { rawValue }
}
