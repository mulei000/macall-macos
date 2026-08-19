import AppKit
import SwiftUI

/// 状态监控设置页：系统监控总开关 + 状态栏模块 + 系统状态 + 通知阈值。
/// 这些原本分散在「通用」与「窗口」页，现按用户要求集中到此板块。
struct StatusMonitorSettingsView: View {
    @ObservedObject var model: SettingsModel

    @Default(.batteryPercentageDisplayLocation) var batteryPercentageDisplayLocation
    @Default(.showBatteryStateInStatusIcon) var showBatteryStateInStatusIcon
    @Default(.statusBarModuleOrder) var statusBarModuleOrder
    @Default(.statusBarHiddenModules) var hiddenModules
    @Default(.statusBarIconVisible) var statusBarIconVisible

    @Default(.systemStatusMetricOrder) var systemStatusMetricOrder
    @Default(.systemStatusHiddenMetrics) var systemStatusHiddenMetrics
    @Default(.disableNotifications) var disableNotifications
    @Default(.notifyCpuTempEnabled) var notifyCpuTempEnabled
    @Default(.cpuTempThreshold) var cpuTempThreshold
    @Default(.notifyPowerEnabled) var notifyPowerEnabled
    @Default(.powerThreshold) var powerThreshold
    @Default(.notifyRamEnabled) var notifyRamEnabled
    @Default(.ramThreshold) var ramThreshold
    @Default(.notifyStorageEnabled) var notifyStorageEnabled
    @Default(.storageThreshold) var storageThreshold
    @Default(.popoverSize) var popoverSize

    @Default(.dashboardSectionOrder) var sectionOrder
    @Default(.dashboardHiddenSections) var hiddenSections

    @State private var testNotificationResult: TestNotificationResult?

    /// 系统监控总开关是否开启（主开关）。驱动次级开关与下方所有监控子设置的可交互性：
    /// 关闭时图标与弹窗入口一并失效，这些子设置灰显。
    private var monitorEnabled: Bool {
        model.config.isFeatureEnabled("monitor", default: true)
    }

    var body: some View {
        IadenteSettingsPage {
            // 模块总开关统一放在卡片右上角（与其他所有功能模块一致）。
            FeatureModuleCard(model: model, featureID: "monitor") {
                IadenteRowDivider()

                IadenteControlRow(
                    IadenteL10n.t("弹窗高度", "Popover height"),
                    subtitle: IadenteL10n.t(
                        "仅调整高度，宽度固定；「自动」会按已开启的模块数量伸缩，且不越过 Dock 上缘。",
                        "Height only. \"Auto\" fits the enabled modules and never overlaps the Dock."),
                    icon: "arrow.up.and.down.text.horizontal",
                    colors: IadenteTheme.dashboardColors
                ) {
                    Picker("", selection: $popoverSize) {
                        ForEach(PopoverSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }

                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(IadenteL10n.t(
                        "刷新频率已由系统自动优化为每 \(Int(SystemMonitor.defaultInterval)) 秒一次，兼顾实时性与能耗。",
                        "Refresh rate is auto-optimized to once every \(Int(SystemMonitor.defaultInterval)) seconds."
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.top, 2)
            }

            Group {
            // 「菜单栏图标」为次级开关，受「系统监控」总开关管制：monitor 关闭时图标强制隐藏。
            IadenteCard(
                IadenteL10n.t("菜单栏图标", "Menu Bar Icon"),
                subtitle: IadenteL10n.t(
                    "次级开关：仅在「系统监控」总开关开启时生效。关闭后图标立即消失、不影响后台采样，可在本页重新开启；系统监控总开关关闭时图标一并隐藏。",
                    "Secondary toggle—only effective when the System Monitor master switch is on. Hiding it takes effect instantly (sampling continues); turning off System Monitor also hides the icon."
                ),
                icon: "menubar.rectangle",
                colors: IadenteTheme.chargingColors
            ) {
                IadenteSettingToggle(
                    IadenteL10n.t("显示菜单栏图标", "Show Menu Bar Icon"),
                    subtitle: IadenteL10n.t(
                        "关闭后状态栏不再显示 macall 图标",
                        "Hides the macall icon from the menu bar"
                    ),
                    icon: "menubar.rectangle",
                    colors: IadenteTheme.chargingColors,
                    isOn: $statusBarIconVisible
                )

                if !monitorEnabled {
                    Text(IadenteL10n.t(
                        "系统监控总开关当前为关闭，菜单栏图标已随之隐藏。",
                        "System Monitor is off, so the menu bar icon is hidden regardless."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            IadenteCard(
                IadenteL10n.t("弹窗模块布局", "Popover Layout"),
                subtitle: IadenteL10n.t(
                    "自定义菜单栏弹窗中显示哪些模块，以及它们的上下顺序。隐藏模块后弹窗会自动缩小，全部显示时自动变大。",
                    "Customize which modules appear in the menu-bar popover and their order. Hiding modules shrinks the popover; showing all expands it."
                ),
                icon: "slider.vertical.3",
                colors: IadenteTheme.dashboardColors
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(sectionOrder.enumerated()), id: \.element) { index, section in
                        SectionRow(
                            section: section,
                            isHidden: hiddenSections.contains(section),
                            isFirst: index == 0,
                            isLast: index == sectionOrder.count - 1,
                            onToggle: { toggleVisibility(section) },
                            onMoveUp: { move(section, direction: .up) },
                            onMoveDown: { move(section, direction: .down) }
                        )

                        if index < sectionOrder.count - 1 {
                            IadenteRowDivider()
                        }
                    }
                }

                IadenteRowDivider()

                Button {
                    resetLayout()
                } label: {
                    Label(
                        IadenteL10n.t("恢复默认布局", "Reset Default Layout"),
                        systemImage: "arrow.counterclockwise"
                    )
                    .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.generalColors))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            IadenteCard(
                IadenteL10n.t("状态栏模块", "Status Bar Modules"),
                subtitle: IadenteL10n.t(
                    "勾选控制显示/隐藏，点击 ↑↓ 调整显示顺序；下方为每个模块的具体设置。",
                    "Toggle to show or hide each module; use ↑↓ to reorder. Module-specific settings are below."
                ),
                icon: "menubar.rectangle",
                colors: IadenteTheme.chargingColors
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(statusBarModuleOrder.enumerated()), id: \.element) { index, module in
                        StatusBarModuleRow(
                            module: module,
                            isHidden: hiddenModules.contains(module),
                            isFirst: index == 0,
                            isLast: index == statusBarModuleOrder.count - 1,
                            onToggle: { toggleModule(module) },
                            onMoveUp: { moveModule(module, .up) },
                            onMoveDown: { moveModule(module, .down) }
                        )

                        if index < statusBarModuleOrder.count - 1 {
                            IadenteRowDivider()
                        }
                    }

                    IadenteRowDivider()

                    VStack(alignment: .leading, spacing: 6) {
                        moduleSettings(for: .batteryIcon)
                        IadenteRowDivider()
                        moduleSettings(for: .batteryPercentage)
                        moduleSettings(for: .systemPower)
                    }
                }
            }

            IadenteCard(
                IadenteL10n.t("系统状态", "System Status"),
                subtitle: IadenteL10n.t(
                    "选择弹窗「系统状态」模块显示哪些项目，点击 ↑↓ 调整顺序。",
                    "Choose which items appear in the popover's System Status module; use ↑↓ to reorder."
                ),
                icon: "gearshape.2.fill",
                colors: IadenteTheme.dashboardColors
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(systemStatusMetricOrder.enumerated()), id: \.element) { index, metric in
                        SystemStatusMetricRow(
                            metric: metric,
                            isHidden: systemStatusHiddenMetrics.contains(metric),
                            isFirst: index == 0,
                            isLast: index == systemStatusMetricOrder.count - 1,
                            onToggle: { toggleStatusMetric(metric) },
                            onMoveUp: { moveStatusMetric(metric, .up) },
                            onMoveDown: { moveStatusMetric(metric, .down) }
                        )

                        if index < systemStatusMetricOrder.count - 1 {
                            IadenteRowDivider()
                        }
                    }
                }
            }

            IadenteCard(
                IadenteL10n.t("通知", "Notifications"),
                subtitle: IadenteL10n.t(
                    "超过设定阈值时发送系统通知；关闭总开关后不再发送任何提醒。",
                    "Send system notifications when thresholds are exceeded."
                ),
                icon: "bell.badge.fill",
                colors: IadenteTheme.automationColors
            ) {
                IadenteSettingToggle(
                    IadenteL10n.t("关闭全部通知", "Disable All Notifications"),
                    subtitle: IadenteL10n.t(
                        "macall 将不再发送任何系统通知",
                        "macall will no longer send any notifications"
                    ),
                    icon: "bell.slash.fill",
                    colors: [IadenteTheme.coral, IadenteTheme.amber],
                    isOn: $disableNotifications
                )

                VStack(alignment: .leading, spacing: 8) {
                    IadenteRowDivider()

                    NotificationThresholdRow(
                        icon: "thermometer.medium",
                        colors: [IadenteTheme.amber, IadenteTheme.gold],
                        title: IadenteL10n.t("CPU 温度", "CPU Temperature"),
                        subtitle: IadenteL10n.t("超过该温度时提醒（需接入 SMC 后生效）", "Requires SMC helper"),
                        unit: "°C",
                        isOn: $notifyCpuTempEnabled,
                        threshold: $cpuTempThreshold
                    )

                    NotificationThresholdRow(
                        icon: "bolt.fill",
                        colors: [IadenteTheme.coral, IadenteTheme.amber],
                        title: IadenteL10n.t("实时功率", "Power Draw"),
                        subtitle: IadenteL10n.t("超过该功耗时提醒（需接入 SMC 后生效）", "Requires SMC helper"),
                        unit: "W",
                        isOn: $notifyPowerEnabled,
                        threshold: $powerThreshold
                    )

                    NotificationThresholdRow(
                        icon: "memorychip",
                        colors: [IadenteTheme.violet, IadenteTheme.pink],
                        title: IadenteL10n.t("运存占用", "RAM Usage"),
                        subtitle: IadenteL10n.t("运行内存 (RAM) 已用比例", "RAM used percentage"),
                        unit: "%",
                        isOn: $notifyRamEnabled,
                        threshold: $ramThreshold
                    )

                    NotificationThresholdRow(
                        icon: "internaldrive",
                        colors: [IadenteTheme.ocean, IadenteTheme.sky],
                        title: IadenteL10n.t("储存内存占用", "Storage Usage"),
                        subtitle: IadenteL10n.t("存储空间 (SSD) 已用比例", "Storage used percentage"),
                        unit: "%",
                        isOn: $notifyStorageEnabled,
                        threshold: $storageThreshold
                    )
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 2)
                        .padding(.leading, 2)
                }

                Divider()
                    .padding(.vertical, 6)

                Button {
                    NotificationService.shared.sendTestNotification { result in
                        testNotificationResult = result
                    }
                } label: {
                    Label(
                        IadenteL10n.t("发送测试通知", "Send Test Notification"),
                        systemImage: "bell.badge.fill"
                    )
                    .font(.callout)
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            .opacity(monitorEnabled ? 1 : 0.45)
            .disabled(!monitorEnabled)
        }
        .alert(item: $testNotificationResult) { result in
            switch result {
            case .delivered:
                return Alert(
                    title: Text(IadenteL10n.t("测试通知已发送", "Test Sent")),
                    message: Text(
                        IadenteL10n.t(
                            "若未看到，请检查屏幕右上角通知中心或勿扰模式。",
                            "If you don't see it, check Notification Center (top-right) or Do Not Disturb."
                        )
                    )
                )
            case .permissionDenied:
                return Alert(
                    title: Text(IadenteL10n.t("通知已被拒绝", "Notifications Denied")),
                    message: Text(
                        IadenteL10n.t(
                            "请在「系统设置 → 通知 → macall」中开启通知权限。",
                            "Enable notifications for macall in System Settings → Notifications."
                        )
                    ),
                    primaryButton: .default(
                        Text(IadenteL10n.t("打开系统设置", "Open System Settings"))
                    ) {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.notifications"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .permissionNotDetermined:
                return Alert(
                    title: Text(IadenteL10n.t("未授权", "Not Authorized")),
                    message: Text(
                        IadenteL10n.t(
                            "请在弹出的系统对话框中允许通知，然后重试。",
                            "Please allow notifications in the system prompt, then try again."
                        )
                    )
                )
            }
        }
    }

    // MARK: - 模块显隐与专属设置

    private func toggleModule(_ module: StatusBarModule) {
        if hiddenModules.contains(module) {
            hiddenModules.removeAll { $0 == module }
        } else {
            hiddenModules.append(module)
        }
    }

    private func moveModule(_ module: StatusBarModule, _ direction: ModuleMoveDirection) {
        var order = statusBarModuleOrder
        guard let index = order.firstIndex(of: module) else { return }
        let target = direction == .up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        statusBarModuleOrder = order
    }

    private func toggleStatusMetric(_ metric: SystemStatusMetric) {
        if systemStatusHiddenMetrics.contains(metric) {
            systemStatusHiddenMetrics.removeAll { $0 == metric }
        } else {
            systemStatusHiddenMetrics.append(metric)
        }
    }

    private func moveStatusMetric(_ metric: SystemStatusMetric, _ direction: ModuleMoveDirection) {
        var order = systemStatusMetricOrder
        guard let index = order.firstIndex(of: metric) else { return }
        let target = direction == .up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        systemStatusMetricOrder = order
    }

    private enum ModuleMoveDirection {
        case up
        case down
    }

    @ViewBuilder
    private func moduleSettings(for module: StatusBarModule) -> some View {
        switch module {
        case .batteryIcon:
            IadenteControlRow(
                IadenteL10n.t("电量数字位置", "Battery Percentage Position"),
                icon: "percent",
                colors: IadenteTheme.chargingColors
            ) {
                Picker("", selection: $batteryPercentageDisplayLocation) {
                    Text(IadenteL10n.t("不显示")).tag(PercentageDisplayLocation.hidden)
                    Text(IadenteL10n.t("图标内")).tag(PercentageDisplayLocation.insideIcon)
                    Text(IadenteL10n.t("图标旁")).tag(PercentageDisplayLocation.nextToIcon)
                }
                .labelsHidden()
                .frame(width: 130)
            }

            IadenteRowDivider()

            IadenteSettingToggle(
                IadenteL10n.t("用颜色显示电池状态", "Show Battery State with Color"),
                subtitle: IadenteL10n.t(
                    "充电、接通电源、低电量使用不同颜色",
                    "Use different colors for charging, plugged-in, and low battery"
                ),
                icon: "paintpalette.fill",
                colors: IadenteTheme.dashboardColors,
                isOn: $showBatteryStateInStatusIcon
            )

        case .batteryPercentage:
            EmptyView()

        case .systemPower:
            IadenteRowDivider()

            Text(IadenteL10n.t(
                "实时系统功耗，单位 W，Times New Roman 字体显示。在「菜单栏模块」中拖拽即可调整它在状态栏的显示顺序。",
                "Live system power draw in watts, shown with Times New Roman font. Drag to reorder in the module list above."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

        default:
            EmptyView()
        }
    }

    // MARK: - 弹窗模块布局

    private func toggleVisibility(_ section: DashboardSection) {
        var hidden = hiddenSections
        if hidden.contains(section) {
            hidden.removeAll { $0 == section }
        } else {
            hidden.append(section)
        }
        hiddenSections = hidden
    }

    private func move(_ section: DashboardSection, direction: MoveDirection) {
        var order = sectionOrder
        guard let index = order.firstIndex(of: section) else { return }
        let target = direction == .up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        sectionOrder = order
    }

    private func resetLayout() {
        sectionOrder = DashboardSection.allCases
        hiddenSections = []
    }

    private enum MoveDirection {
        case up
        case down
    }
}

// MARK: - Shared row components

private struct StatusBarModuleRow: View {
    let module: StatusBarModule
    let isHidden: Bool
    let isFirst: Bool
    let isLast: Bool
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ReorderControl(isFirst: isFirst, isLast: isLast, onUp: onMoveUp, onDown: onMoveDown)

            Image(systemName: module.icon)
                .frame(width: 20)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title)
                    .font(.system(size: 13, weight: .medium))
                Text(module.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { !isHidden },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(IadenteTheme.jade)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct SystemStatusMetricRow: View {
    let metric: SystemStatusMetric
    let isHidden: Bool
    let isFirst: Bool
    let isLast: Bool
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ReorderControl(isFirst: isFirst, isLast: isLast, onUp: onMoveUp, onDown: onMoveDown)

            IadenteIconBadge(icon: metric.icon, colors: metric.colors, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(.system(size: 13, weight: .medium))
                Text(metric.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { !isHidden },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(IadenteTheme.jade)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct NotificationThresholdRow: View {
    let icon: String
    let colors: [Color]
    let title: String
    let subtitle: String
    let unit: String
    @Binding var isOn: Bool
    @Binding var threshold: Double

    var body: some View {
        HStack(spacing: 10) {
            IadenteIconBadge(icon: icon, colors: colors, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                TextField("", value: $threshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12))
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(IadenteTheme.jade)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 弹窗模块行

private struct SectionRow: View {
    @Default(.appLanguage) private var appLanguage

    let section: DashboardSection
    let isHidden: Bool
    let isFirst: Bool
    let isLast: Bool
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ReorderControl(isFirst: isFirst, isLast: isLast, onUp: onMoveUp, onDown: onMoveDown)

            IadenteIconBadge(icon: section.icon, colors: section.colors, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.system(size: 13, weight: .medium))
                Text(section.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle(
                "",
                isOn: Binding(
                    get: { !isHidden },
                    set: { _ in onToggle() }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(IadenteTheme.jade)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
    }
}
