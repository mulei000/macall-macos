import AppKit
import SwiftUI

/// macall 设置窗口主视图。
/// 整体风格沿用 macometer 的设置页：IadenteWindowBackdrop 背景 + 左侧分栏导航
/// + 右侧内容区。左侧导航为后续新增功能留出扩展空间（顶部不再占用横向空间）。
/// 标签页按用户要求重组为：通用 / 窗口与分屏 / 状态监控 / 高级 / 关于（快捷键
/// 已拆分到各功能板块内部，不再单独成页）。
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Default(.appLanguage) private var appLanguage
    @Environment(\.colorScheme) private var colorScheme

    @State private var tab: MacallSettingsTab

    init(model: SettingsModel, initialTab: MacallSettingsTab = .general) {
        self.model = model
        self._tab = State(wrappedValue: initialTab)
    }

    var body: some View {
        ZStack {
            IadenteWindowBackdrop()

            HStack(spacing: 0) {
                sidebar
                Divider()
                    .frame(maxHeight: .infinity)
                content
            }
        }
        .tint(IadenteTheme.jade)
        .frame(width: 960, height: 660)
        .onAppear { updateWindowTitle() }
        .onChange(of: appLanguage) { _, _ in updateWindowTitle() }
    }

    // MARK: - 左侧导航

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌区
            HStack(spacing: 11) {
                IadenteIconBadge(
                    icon: "macwindow.badge.plus",
                    colors: [IadenteTheme.jade, IadenteTheme.ocean],
                    size: 34
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("macall")
                        .font(.system(size: 16, weight: .bold))
                    Text(IadenteL10n.t("多合一效率工具"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()
                .padding(.horizontal, 12)

            // 分栏项
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(MacallSettingsTab.allCases) { t in
                        sidebarRow(t)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 0)
        }
        .frame(width: 220)
        .background {
            Color(
                nsColor: colorScheme == .dark
                    ? NSColor(calibratedRed: 0.10, green: 0.095, blue: 0.09, alpha: 1.0)
                    : NSColor(calibratedWhite: 0.965, alpha: 1.0)
            )
        }
    }

    private func sidebarRow(_ t: MacallSettingsTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { tab = t }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: t.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22, alignment: .center)
                Text(t.title)
                    .font(.system(size: 13.5, weight: tab == t ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if tab == t {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.16))
                }
            }
            .foregroundStyle(tab == t ? Color.accentColor : Color.primary)
            // 整块（含圆角高亮区与右侧留白）都是命中区，点击任意位置都能切换，
            // 而不只是标题汉字那一点。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右侧内容

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            // 顶部细标题栏（为后续功能预留空间，不再放分段选择器）
            HStack(spacing: 10) {
                IadenteIconBadge(icon: tab.icon, colors: tab.colors, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title)
                        .font(.system(size: 15, weight: .bold))
                    if let sub = tab.subtitle {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background {
                Color(
                    nsColor: colorScheme == .dark
                        ? NSColor(calibratedRed: 0.095, green: 0.09, blue: 0.085, alpha: 0.98)
                        : NSColor(calibratedWhite: 0.99, alpha: 0.96)
                )
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.primary.opacity(0.12))
                    .frame(height: 1)
            }

            Group {
                switch tab {
                case .general:        GeneralSettingsView(model: model)
                case .windowSnap:     WindowSnapSettingsView(model: model)
                case .windowLayout:   WindowLayoutSettingsView(model: model)
                case .clipboard:      ClipboardSettingsView(model: model)
                case .audio:          VolumeSettingsView(model: model)
                case .display:        DisplaySettingsView(model: model)
                case .trackpadMouse:  TrackpadMouseSettingsView(model: model)
                case .tools:          ToolsSettingsView(model: model)
                case .statusMonitor:  StatusMonitorSettingsView(model: model)
                case .advanced:       AdvancedSettingsView()
                case .about:          AboutSettingsView()
                }
            }
            .environment(\.settingsTab, tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 740)
    }

    private func updateWindowTitle() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.title = IadenteL10n.t(
                "macall 设置",
                "macall Settings"
            )
        }
    }
}

// MARK: - Tab 枚举

/// 侧边栏分栏。每一栏对应一组「同类功能模块」，模块的总开关就长在自己那一栏里，
/// 不再有一个集中罗列所有模块的「功能」页。
enum MacallSettingsTab: Hashable, CaseIterable, Identifiable {
    case general
    case windowSnap
    case windowLayout
    case clipboard
    case audio
    case display
    case trackpadMouse
    case tools
    case statusMonitor
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general:       return IadenteL10n.t("通用", "General")
        case .windowSnap:    return IadenteL10n.t("窗口与分屏", "Windows & Snapping")
        case .windowLayout:  return IadenteL10n.t("场景布局", "Scene Layout")
        case .clipboard:     return IadenteL10n.t("剪贴板", "Clipboard")
        case .audio:         return IadenteL10n.t("声音", "Audio")
        case .display:       return IadenteL10n.t("屏幕", "Screen")
        case .trackpadMouse: return IadenteL10n.t("触控板与鼠标", "Trackpad & Mouse")
        case .tools:         return IadenteL10n.t("工具箱", "Toolbox")
        case .statusMonitor: return IadenteL10n.t("状态监控", "Monitoring")
        case .advanced:      return IadenteL10n.t("高级", "Advanced")
        case .about:         return IadenteL10n.t("关于", "About")
        }
    }

    var subtitle: String? {
        switch self {
        case .general:       return IadenteL10n.t("总开关、语言、外观、登录启动、权限", "Master switch, language, appearance, launch, permissions")
        case .windowSnap:    return IadenteL10n.t("吸附、隐藏、跨屏、置顶、边缘吸附、窗口切换", "Snap, hide, display move, always-on-top, edge snap, switcher")
        case .windowLayout:  return IadenteL10n.t("按场景保存与还原各 App 的窗口位置", "Save & restore app window positions per scene")
        case .clipboard:     return IadenteL10n.t("剪贴板历史与图片文字识别", "Clipboard history and image OCR")
        case .audio:         return IadenteL10n.t("主音量、逐 App 音量、输出设备、麦克风、系统提示音", "Master & per-app volume, output devices, mic, system sounds")
        case .display:       return IadenteL10n.t("外接显示器控制、放大镜、屏幕取色", "External monitor control, magnifier, color picker")
        case .trackpadMouse: return IadenteL10n.t("触控板边缘手势、鼠标滚轮平滑 / 反转 / 侧键绑定", "Trackpad edge gestures, mouse wheel smoothing / invert / side-button bindings")
        case .tools:         return IadenteL10n.t("文字片段、二维码、启动器、电源与外观", "Snippets, QR codes, launcher, power & appearance")
        case .statusMonitor: return IadenteL10n.t("菜单栏模块、系统状态、通知阈值", "Menu bar modules, system status, notification thresholds")
        case .advanced:      return IadenteL10n.t("数据、缓存、日志", "Data, cache, logs")
        case .about:         return IadenteL10n.t("版本与许可证", "Version and license")
        }
    }

    var icon: String {
        switch self {
        case .general:       return "gearshape.fill"
        case .windowSnap:    return "rectangle.split.2x2"
        case .windowLayout:  return "square.grid.2x2"
        case .clipboard:     return "doc.on.clipboard"
        case .audio:         return "speaker.wave.2.fill"
        case .display:       return "display"
        case .trackpadMouse: return "computermouse.fill"
        case .tools:         return "wrench.and.screwdriver.fill"
        case .statusMonitor: return "chart.bar.fill"
        case .advanced:      return "slider.horizontal.3"
        case .about:         return "heart.text.square.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .general:       return IadenteTheme.generalColors
        case .windowSnap:    return IadenteTheme.generalColors
        case .windowLayout:  return IadenteTheme.generalColors
        case .clipboard:     return IadenteTheme.automationColors
        case .audio:         return IadenteTheme.advancedColors
        case .display:       return IadenteTheme.dashboardColors
        case .trackpadMouse: return IadenteTheme.dashboardColors
        case .tools:         return IadenteTheme.aboutColors
        case .statusMonitor: return IadenteTheme.dashboardColors
        case .advanced:      return IadenteTheme.advancedColors
        case .about:         return IadenteTheme.aboutColors
        }
    }

    /// 当前板块实际用到的权限。用于各设置页底部的「本部分用到的权限」汇总卡。
    /// 通用页不在此列出（它的权限面板已汇总全部权限）。
    var requiredPermissions: [RequiredPermission] {
        switch self {
        case .windowSnap:    return [.accessibility, .inputMonitoring, .screenRecording]
        case .windowLayout:  return [.accessibility]
        case .clipboard:     return [.inputMonitoring]
        case .trackpadMouse: return [.accessibility, .inputMonitoring]
        default:             return []
        }
    }
}

// MARK: - 当前板块环境键

/// 让 `IadenteSettingsPage` 能感知当前设置板块，从而自动追加对应的权限 footer。
private struct SettingsTabKey: EnvironmentKey {
    static let defaultValue: MacallSettingsTab = .general
}

extension EnvironmentValues {
    var settingsTab: MacallSettingsTab {
        get { self[SettingsTabKey.self] }
        set { self[SettingsTabKey.self] = newValue }
    }
}
