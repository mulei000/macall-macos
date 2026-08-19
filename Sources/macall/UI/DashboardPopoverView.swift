import AppKit
import SwiftUI

private struct ContentRegionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 320
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct DashboardPopoverView: View {
    let viewModel: MenuViewModel
    let onOpenSettings: (SettingsTab) -> Void
    let onQuit: () -> Void
    /// 点击"查看全部耗电应用"时打开独立窗口。
    let onShowAllEnergyApps: () -> Void
    /// 内容区（不含固定底部栏）高度变化时回调，用于让状态栏弹窗/预览窗口自适应尺寸。
    var onContentHeight: ((CGFloat) -> Void)? = nil

    /// 「随功能自适应」档内容区允许的最大高度（= 状态栏按钮下方到 Dock 上缘的可用高度 − 底部栏）。
    /// 由 StatusBarManager 在打开前传入，用于正确夹紧 ScrollView，避免内容超出时既不滚动又留白。
    var maxContentHeight: CGFloat = 10_000

    @Default(.showBatteryTemperature) private var showBatteryTemperature
    @Default(.appLanguage) private var appLanguage
    @Default(.dashboardSectionOrder) private var sectionOrder
    @Default(.dashboardHiddenSections) private var hiddenSections
    @Default(.systemStatusHiddenMetrics) private var systemStatusHiddenMetrics
    @Default(.systemStatusMetricOrder) private var systemStatusMetricOrder
    @Default(.popoverSize) private var popoverSize

    /// 内容区（不含底部固定栏）的实际自然高度，由 ContentRegionHeightKey 测量得到。
    /// 在「随功能自适应」档位下，用此高度代替 ScrollView 的贪婪布局，避免模块少时底部留白。
    @State private var measuredContentHeight: CGFloat = 0

    private var visibleSections: [DashboardSection] {
        sectionOrder.filter { !hiddenSections.contains($0) }
    }

    var body: some View {
        ZStack {
            IadenteWindowBackdrop()

            VStack(spacing: 0) {
                // 内容区：可滚动，高度受 popoverSize 档位限制（仅长度变化，宽度固定 320）。
                ScrollView(showsIndicators: false) {
                    contentBody
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ContentRegionHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                }
                .frame(maxHeight: contentRegionMaxHeight)

                // 底部栏（设置 / 刷新 / 退出）：固定在最底，始终可见，不随内容滚动。
                footer
            }
            .frame(width: 320)
        }
        .frame(width: 320)
        .tint(IadenteTheme.jade)
        .onPreferenceChange(ContentRegionHeightKey.self) { height in
            measuredContentHeight = height
            onContentHeight?(height)
        }
    }

    /// 不带 ScrollView / 底部栏 / 背景的内容主体，用于离屏测量真实内容高度。
    @ViewBuilder
    private var contentBody: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(.primary.opacity(0.11))
                .frame(height: 1)
                .padding(.horizontal, 14)

            if visibleSections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(IadenteL10n.t("暂未选择任何模块", "No modules selected"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                VStack(spacing: 8) {
                    ForEach(visibleSections) { section in
                        sectionView(for: section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        // fixedSize(vertical: true)：强制内容按真实（理想）高度布局，不被外层 ScrollView 的
        // maxHeight 提案压成「视口高度」。这样无论离屏测量还是运行期 GeometryReader 读到的都是
        // 真实内容高度——否则内容超高时量到的只是面板高度，大档面板会系统性偏短、需要滚动。
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 在离屏 NSHostingController 中测量 contentBody 的自然高度（不含底部栏）。
    /// 只测量内容视图本身（无 ScrollView / 无背景 / 无 footer），避免完整 DashboardPopoverView
    /// 在 sizeThatFits 时触发 SIGTRAP。
    ///
    /// 测量用 `NSHostingController.sizeThatFits(in:)`：这是 AppKit 为托管视图提供的标准测高 API，
    /// 对 `contentBody`（无 ScrollView、且已 `.fixedSize(vertical:true)`）会得到有限的理想高度。
    /// **绝不要**改用 `view.fittingSize` + 一个离屏 `NSWindow`：那种写法会触发 SwiftUI 布局引擎在
    /// 未上屏的 hosting view 上做同步布局、访问到已释放的内部节点 → SIGSEGV
    /// （build 44/45 的「点击状态栏崩溃」就是这个根因）。这里只建一个 NSHostingController、
    /// 不挂窗口、不 orderFront，sizeThatFits 是纯计算、零副作用。
    static func measureContentHeight(viewModel: MenuViewModel) -> CGFloat {
        let view = DashboardPopoverView(
            viewModel: viewModel,
            onOpenSettings: { _ in },
            onQuit: {},
            onShowAllEnergyApps: {},
            onContentHeight: nil,
            maxContentHeight: 10_000
        )
        let controller = NSHostingController(rootView: view.contentBody)
        let size = controller.sizeThatFits(
            in: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        )
        let h: CGFloat
        if size.height.isFinite, size.height > 0 {
            h = size.height
        } else {
            // sizeThatFits 偶发返回 0 / 非有限值时的兜底，避免面板高度崩成 0。
            h = 480
        }
        return max(h, 1)
    }

    /// 内容区最大高度：固定档位用原值；「随功能自适应」用传入的可用高度（状态栏下沿→Dock 上缘−底栏），
    /// 让 ScrollView 先按完整可用高度布局。内容少则 onContentHeight 回调把面板缩到内容高度，
    /// 内容多就保持可用高度并内部滚动。这里不再用离屏 sizeThatFits 预量，避免 SIGTRAP。
    private var contentRegionMaxHeight: CGFloat {
        switch popoverSize {
        case .auto:
            return maxContentHeight
        default:
            return popoverSize.contentRegionMaxHeight
        }
    }

    @ViewBuilder
    private func sectionView(for section: DashboardSection) -> some View {
        switch section {
        case .hero: statusHero
        case .batteryOverview: batterySummary
        case .powerFlow: powerSummary
        case .energyApps: energyAppRanking
        case .quickLinks: settingsLinks
        case .systemStatus: systemStatusSection
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    viewModel.adapterConnected
                        ? IadenteL10n.t("电源已连接")
                        : IadenteL10n.t("正在使用电池")
                )
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(viewModel.batteryModeText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showBatteryTemperature {
                Label(viewModel.batteryTemperatureText, systemImage: "thermometer.medium")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IadenteTheme.jade)
            }

            Rectangle()
                .fill(.primary.opacity(0.16))
                .frame(width: 1, height: 22)

            Text(viewModel.batteryPercentageText)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var statusHero: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(
                    systemName: viewModel.adapterConnected
                        ? (viewModel.isCharging ? "bolt.fill" : "powerplug.fill")
                        : "battery.75percent"
                )
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? .white : .primary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(statusTint.opacity(0.17))
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.batteryModeText)
                        .font(.system(size: 13, weight: .bold))
                    Text(
                        viewModel.adapterConnected
                            ? IadenteL10n.t(
                                "适配器 \(viewModel.externalInputText)",
                                "Adapter \(viewModel.externalInputText)"
                            )
                            : IadenteL10n.t(
                                "电池 \(viewModel.internalInputText)",
                                "Battery \(viewModel.internalInputText)"
                            )
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()
            }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [
                                Color(red: 0.115, green: 0.145, blue: 0.18).opacity(0.95),
                                Color(red: 0.065, green: 0.075, blue: 0.09).opacity(0.92),
                            ]
                            : [
                                Color(red: 0.92, green: 0.94, blue: 0.96).opacity(0.95),
                                Color(red: 0.88, green: 0.90, blue: 0.93).opacity(0.92),
                            ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(statusTint)
                .frame(width: 2)
                .shadow(color: statusTint, radius: 6)
                .padding(.vertical, 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.primary.opacity(colorScheme == .dark ? 0.14 : 0.18), lineWidth: 1)
        }
        .shadow(color: statusTint.opacity(0.12), radius: 8, y: 3)
    }

    private var batterySummary: some View {
        PopoverCompactCard {
            HStack(spacing: 0) {
                CompactMetric(
                    title: IadenteL10n.t("电池健康", "Battery Health"),
                    value: viewModel.batteryHealthText,
                    tint: IadenteTheme.jade
                )
                CompactDivider()
                CompactMetric(
                    title: IadenteL10n.t("循环次数", "Cycle Count"),
                    value: viewModel.cycleCountText,
                    tint: IadenteTheme.violet
                )
                CompactDivider()
                CompactMetric(
                    title: IadenteL10n.t("剩余时间", "Time Remaining"),
                    value: viewModel.timeRemainingText,
                    tint: IadenteTheme.amber,
                    compact: true
                )
            }
        }
    }

    private var powerSummary: some View {
        PopoverCompactCard {
            VStack(spacing: 6) {
                HStack {
                    Label(
                        IadenteL10n.t("实时功率分流"),
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(viewModel.powerSourceText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                CompactPowerFlowDiagram(
                    powerSource: viewModel.powerSource,
                    isCharging: viewModel.isCharging,
                    adapterPower: viewModel.adapterPower,
                    systemPower: viewModel.systemPower,
                    batteryPower: viewModel.batteryPower
                )
            }
        }
    }

    private var energyAppRanking: some View {
        PopoverCompactCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        IadenteL10n.t("当前耗电 App"),
                        systemImage: "bolt.horizontal.circle.fill"
                    )
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(IadenteL10n.t("按处理器活动实时估算"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                if !viewModel.hasEnergyUsageSample {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(IadenteL10n.t("正在采样当前应用活动…"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                } else if viewModel.topEnergyApps.isEmpty {
                    Text(IadenteL10n.t("当前没有检测到明显耗电的前台应用"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                } else {
                    let apps = Array(viewModel.topEnergyApps.prefix(3))
                    let maximum = max(
                        apps.map(\.cpuUsage).max() ?? 1,
                        1
                    )
                    ForEach(0..<3, id: \.self) { index in
                        if index < apps.count {
                            EnergyAppRow(
                                rank: index + 1,
                                app: apps[index],
                                maximumCPUUsage: maximum,
                                tint: energyTint(for: index)
                            )
                        } else {
                            EnergyAppPlaceholderRow()
                        }
                    }

                    Rectangle()
                        .fill(.primary.opacity(0.10))
                        .frame(height: 1)
                        .padding(.vertical, 2)

                    Button(action: onShowAllEnergyApps) {
                        HStack(spacing: 6) {
                            Label(
                                IadenteL10n.t("查看全部耗电应用"),
                                systemImage: "list.bullet"
                            )
                            .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text(String(format: "%.1f%%+", 0.1))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var systemStatusSection: some View {
        PopoverCompactCard {
            VStack(spacing: 6) {
                HStack {
                    Label(
                        IadenteL10n.t("系统状态"),
                        systemImage: "gearshape.2.fill"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(IadenteL10n.t("实时硬件监测"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                let hidden = Set(systemStatusHiddenMetrics)
                let metrics = systemStatusMetricOrder.filter { !hidden.contains($0) }
                if metrics.isEmpty {
                    Text(IadenteL10n.t("已隐藏全部项目，可在「设置 → 仪表盘」中开启"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    let columns = [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ]
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(metrics) { metric in
                            tile(for: metric)
                        }
                    }
                }
            }
        }
    }

    private func tile(for metric: SystemStatusMetric) -> some View {
        SystemStatusTile(icon: metric.icon, tint: metric.tint, title: metric.shortTitle) {
            if metric == .network {
                networkValueView(up: viewModel.networkUpMBps, down: viewModel.networkDownMBps)
                    .foregroundStyle(metric.tint)
            } else {
                systemStatusValueText(for: metric)
            }
        }
    }

    /// 系统状态卡片中数值的统一样式：四个被圈住的指标（CPU 温度、CPU 占用、内存、磁盘）使用相同字体字号。
    private func systemStatusValueText(for metric: SystemStatusMetric) -> some View {
        Text(valueText(for: metric))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(metric.tint)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
    }

    /// 网速单位自适应：< 1 MB/s 显示 K，≥ 1 MB/s 显示 M，节省宽度避免截断。
    private func networkSpeedText(_ mbps: Double) -> String {
        if mbps < 0 { return "—" }
        if mbps < 1 {
            return "\(Int(mbps * 1000))K"
        }
        return "\(mbps.formatted(.number.precision(.fractionLength(1))))M"
    }

    @ViewBuilder
    private func networkValueView(up: Double, down: Double) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 6, weight: .bold))
                Text(networkSpeedText(up))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack(spacing: 1) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 6, weight: .bold))
                Text(networkSpeedText(down))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private func valueText(for metric: SystemStatusMetric) -> String {
        let nf1 = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        let nf0 = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        switch metric {
        case .memory:
            return "\(viewModel.memoryUsedGB.formatted(nf1)) GB"
        case .disk:
            return "\(viewModel.diskFreeGB.formatted(nf0)) GB"
        case .cpuTemp:
            return viewModel.cpuTemperatureC >= 0
                ? "\(viewModel.cpuTemperatureC.formatted(nf1))°C"
                : "—"
        case .fan:
            return viewModel.fanRPM >= 0
                ? "\(viewModel.fanRPM.formatted(nf0))"
                : "—"
        case .network:
            let up = viewModel.networkUpMBps
            let down = viewModel.networkDownMBps
            if up < 0 || down < 0 { return "—" }
            return "↑\(up.formatted(nf1)) ↓\(down.formatted(nf1))"
        case .cpu:
            return viewModel.cpuUsagePercent >= 0
                ? "\(viewModel.cpuUsagePercent.formatted(nf0))%"
                : "—"
        }
    }

    private var settingsLinks: some View {
        HStack(spacing: 9) {
            DashboardLinkButton(
                title: IadenteL10n.t("设置详情", "Settings Details"),
                icon: "info.circle"
            ) {
                onOpenSettings(.general)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("macall")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            IadenteTheme.violet,
                            IadenteTheme.jade,
                            IadenteTheme.pink,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Text(IadenteL10n.t("实时电脑检测", "Live Computer Monitoring"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            FooterButton(icon: "arrow.clockwise") {
                viewModel.refresh()
            }
            FooterButton(icon: "gearshape.fill") {
                onOpenSettings(.general)
            }
            FooterButton(icon: "power") {
                onQuit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.10))
                .frame(height: 1)
        }
    }

    private var statusTint: Color {
        if viewModel.isCharging { return IadenteTheme.amber }
        return IadenteTheme.jade
    }

    private func energyTint(for index: Int) -> Color {
        switch index {
        case 0: IadenteTheme.amber
        case 1: IadenteTheme.ocean
        default: IadenteTheme.violet
        }
    }
}

private struct CompactPowerFlowDiagram: View {
    @Default(.appLanguage) private var appLanguage

    let powerSource: PowerSource
    let isCharging: Bool
    let adapterPower: Double
    let systemPower: Double
    let batteryPower: Double

    private let nodeWidth: CGFloat = 92
    private let nodeHeight: CGFloat = 36

    /// 固定高度：取三节点模式所需的最大高度，避免在充/放电等不同分配形式之间跳动。
    private let diagramHeight: CGFloat = 86

    var body: some View {
        GeometryReader { geometry in
            let leftX = nodeWidth / 2
            let rightX = geometry.size.width - nodeWidth / 2
            let topY: CGFloat = nodeHeight / 2
            let middleY = diagramHeight / 2
            let bottomY = diagramHeight - nodeHeight / 2

            ZStack {
                Canvas { context, _ in
                    drawFlows(
                        context: context,
                        leftX: leftX + nodeWidth / 2 - 5,
                        rightX: rightX - nodeWidth / 2 + 5,
                        topY: topY,
                        middleY: middleY,
                        bottomY: bottomY
                    )
                }

                switch diagramMode {
                case .adapterSplit:
                    PowerFlowNode(
                        title: IadenteL10n.t("适配器", "Adapter"),
                        icon: "powerplug.fill",
                        power: adapterPower,
                        tint: IadenteTheme.amber
                    )
                    .position(x: leftX, y: middleY)

                    PowerFlowNode(
                        title: IadenteL10n.t("电池充入", "Battery Charging"),
                        icon: isCharging ? "battery.100.bolt" : "battery.100",
                        power: batteryPower,
                        tint: IadenteTheme.jade
                    )
                    .position(x: rightX, y: topY)

                    PowerFlowNode(
                        title: IadenteL10n.t("系统使用", "System Usage"),
                        icon: "laptopcomputer",
                        power: systemPower,
                        tint: IadenteTheme.ocean
                    )
                    .position(x: rightX, y: bottomY)

                case .sourcesMerge:
                    PowerFlowNode(
                        title: IadenteL10n.t("电池输出", "Battery Output"),
                        icon: "battery.100",
                        power: batteryPower,
                        tint: IadenteTheme.jade
                    )
                    .position(x: leftX, y: topY)

                    PowerFlowNode(
                        title: IadenteL10n.t("适配器", "Adapter"),
                        icon: "powerplug.fill",
                        power: adapterPower,
                        tint: IadenteTheme.amber
                    )
                    .position(x: leftX, y: bottomY)

                    PowerFlowNode(
                        title: IadenteL10n.t("系统使用", "System Usage"),
                        icon: "laptopcomputer",
                        power: systemPower,
                        tint: IadenteTheme.ocean
                    )
                    .position(x: rightX, y: middleY)

                case .adapterOnly:
                    PowerFlowNode(
                        title: IadenteL10n.t("适配器", "Adapter"),
                        icon: "powerplug.fill",
                        power: adapterPower,
                        tint: IadenteTheme.amber
                    )
                    .position(x: leftX, y: middleY)

                    PowerFlowNode(
                        title: IadenteL10n.t("系统使用", "System Usage"),
                        icon: "laptopcomputer",
                        power: systemPower,
                        tint: IadenteTheme.ocean
                    )
                    .position(x: rightX, y: middleY)

                case .batteryOnly:
                    PowerFlowNode(
                        title: IadenteL10n.t("电池输出", "Battery Output"),
                        icon: "battery.100",
                        power: batteryPower,
                        tint: IadenteTheme.jade
                    )
                    .position(x: leftX, y: middleY)

                    PowerFlowNode(
                        title: IadenteL10n.t("系统使用", "System Usage"),
                        icon: "laptopcomputer",
                        power: systemPower,
                        tint: IadenteTheme.ocean
                    )
                    .position(x: rightX, y: middleY)
                }
            }
        }
        .frame(height: diagramHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IadenteL10n.t("实时功率分流图", "Live Power Flow Diagram"))
        .accessibilityValue(
            IadenteL10n.t(
                "适配器 \(formatted(adapterPower))，系统 \(formatted(systemPower))，电池 \(formatted(batteryPower))",
                "Adapter \(formatted(adapterPower)), system \(formatted(systemPower)), battery \(formatted(batteryPower))"
            )
        )
    }

    private enum DiagramMode {
        case adapterSplit
        case sourcesMerge
        case adapterOnly
        case batteryOnly
    }

    private var diagramMode: DiagramMode {
        switch powerSource {
        case .acAdapter:
            batteryPower > 0.05 ? .adapterSplit : .adapterOnly
        case .both:
            .sourcesMerge
        case .battery:
            .batteryOnly
        }
    }

    private func drawFlows(
        context: GraphicsContext,
        leftX: CGFloat,
        rightX: CGFloat,
        topY: CGFloat,
        middleY: CGFloat,
        bottomY: CGFloat
    ) {
        switch diagramMode {
        case .adapterSplit:
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: middleY),
                to: CGPoint(x: rightX, y: topY),
                power: batteryPower,
                startColor: IadenteTheme.amber,
                endColor: IadenteTheme.jade
            )
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: middleY),
                to: CGPoint(x: rightX, y: bottomY),
                power: systemPower,
                startColor: IadenteTheme.amber,
                endColor: IadenteTheme.ocean
            )

        case .sourcesMerge:
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: topY),
                to: CGPoint(x: rightX, y: middleY),
                power: batteryPower,
                startColor: IadenteTheme.jade,
                endColor: IadenteTheme.ocean
            )
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: bottomY),
                to: CGPoint(x: rightX, y: middleY),
                power: adapterPower,
                startColor: IadenteTheme.amber,
                endColor: IadenteTheme.ocean
            )

        case .adapterOnly:
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: middleY),
                to: CGPoint(x: rightX, y: middleY),
                power: adapterPower,
                startColor: IadenteTheme.amber,
                endColor: IadenteTheme.ocean
            )

        case .batteryOnly:
            drawFlow(
                context: context,
                from: CGPoint(x: leftX, y: middleY),
                to: CGPoint(x: rightX, y: middleY),
                power: systemPower,
                startColor: IadenteTheme.jade,
                endColor: IadenteTheme.ocean
            )
        }
    }

    private func drawFlow(
        context: GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        power: Double,
        startColor: Color,
        endColor: Color
    ) {
        let controlX = start.x + (end.x - start.x) * 0.50
        let path = Path { path in
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: controlX, y: start.y),
                control2: CGPoint(x: controlX, y: end.y)
            )
        }
        let width = min(max(CGFloat(sqrt(abs(power))) * 1.15, 3), 8)

        context.stroke(
            path,
            with: .color(Color.primary.opacity(0.18)),
            style: StrokeStyle(lineWidth: width + 3, lineCap: .round)
        )
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    startColor.opacity(0.82),
                    endColor.opacity(0.88),
                ]),
                startPoint: start,
                endPoint: end
            ),
            style: StrokeStyle(lineWidth: width, lineCap: .round)
        )

        var arrow = Path()
        arrow.move(to: CGPoint(x: end.x - 1, y: end.y))
        arrow.addLine(to: CGPoint(x: end.x - 8, y: end.y - 5))
        arrow.addLine(to: CGPoint(x: end.x - 8, y: end.y + 5))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(endColor.opacity(0.95)))
    }

    private func formatted(_ power: Double) -> String {
        String(format: "%.2f W", abs(power))
    }
}

private struct PowerFlowNode: View {
    @Default(.appLanguage) private var appLanguage

    let title: String
    let icon: String
    let power: Double
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(IadenteL10n.t(title))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(String(format: "%.2f W", abs(power)))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: 92, height: 36)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(tint.opacity(0.30), lineWidth: 1)
                }
        }
        .shadow(color: tint.opacity(0.12), radius: 4, y: 2)
    }
}

private struct PopoverCompactCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(10)
            .background {
                PopoverCardBackground()
            }
    }
}

private struct PopoverCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [
                            Color.white.opacity(0.05),
                            Color.black.opacity(0.06),
                        ]
                        : [
                            Color.white.opacity(0.72),
                            Color(red: 0.95, green: 0.96, blue: 0.98).opacity(0.55),
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.18 : 0.85),
                                .black.opacity(colorScheme == .dark ? 0.12 : 0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }
}

private struct CompactDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.11))
            .frame(width: 1, height: 28)
    }
}

private struct CompactMetric: View {
    @Default(.appLanguage) private var appLanguage

    let title: String
    let value: String
    let tint: Color
    var compact = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(
                    .system(
                        size: compact ? 11 : 14,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
            Text(IadenteL10n.t(title))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SystemStatusTile<Value: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        VStack(spacing: 0) {
            // 图标 + 数据：固定同高上排，保证 6 个框图标位置一致
            HStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(
                        tint.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )

                Spacer(minLength: 0)

                value()

                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 汉字标签：固定行高、统一字号、居中
            Text(IadenteL10n.t(title))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 13)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(7)
        .frame(height: 58)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
                )
        }
    }
}

private struct CompactActionRow: View {
    @Default(.appLanguage) private var appLanguage

    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(IadenteL10n.t(title))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(IadenteL10n.t(subtitle))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(IadenteL10n.t(isOn ? "开启" : "关闭"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isOn ? tint : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill((isOn ? tint : Color.secondary).opacity(0.12))
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EnergyAppRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let rank: Int
    let app: AppEnergyUsageSnapshot
    let maximumCPUUsage: Double
    let tint: Color
    var onForceClose: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("\(rank)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .frame(width: 12)
                    Text(app.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%%", app.cpuUsage))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.09))
                        Capsule()
                            .fill(tint)
                            .frame(
                                width: max(
                                    2,
                                    geometry.size.width
                                        * min(app.cpuUsage / maximumCPUUsage, 1)
                                )
                            )
                    }
                }
                .frame(height: 2.5)
            }

            Spacer(minLength: 4)

            if let onForceClose {
                Button(action: onForceClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help(IadenteL10n.t("强制关闭", "Force Close"))
            }
        }
    }
}

/// 耗电 App 列表不足 3 个时的占位行，高度与 EnergyAppRow 一致，避免卡片高度跳动。
private struct EnergyAppPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.clear)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(" ")
                    .font(.system(size: 11, weight: .semibold))
                Capsule()
                    .fill(Color.clear)
                    .frame(height: 2.5)
            }

            Spacer(minLength: 4)
        }
        .frame(height: 22)
    }
}

private struct ProtectionPill: View {
    @Default(.appLanguage) private var appLanguage
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isEnabled ? IadenteTheme.jade : Color.secondary)
                .frame(width: 6, height: 6)
            Text(IadenteL10n.t(title))
                .font(.system(size: 10.5, weight: .medium))
            Text(IadenteL10n.t(isEnabled ? "开" : "关"))
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isEnabled ? IadenteTheme.jade : .secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.06))
        )
    }
}

private struct DashboardLinkButton: View {
    @Default(.appLanguage) private var appLanguage

    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(IadenteL10n.t(title), systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background {
            PopoverCardBackground()
        }
    }
}

private struct FooterButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 19)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.09))
                )
        }
        .buttonStyle(.plain)
    }
}
