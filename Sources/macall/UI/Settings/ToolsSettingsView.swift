import AppKit
import SwiftUI

/// 工具箱设置页：文字片段 / 二维码 / 电源与外观。
/// 这些都是「按一下就出面板」的小工具，各自的总开关在自己卡片右上角。
struct ToolsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        IadenteSettingsPage {
            // 工具箱：独立状态栏图标 + 面板内工具的顺序与显隐。
            ToolboxManagerCard()

            // 清洁模式：总开关 + 快捷键 + 自动熄屏 + 自动解锁倒计时。
            FeatureModuleCard(model: model, featureID: "keyboardclean") {
                CleanCountdownRow()
            }

            FeatureModuleCard(model: model, featureID: "snippets") {
                SnippetLibraryEntry()
            }

            FeatureModuleCard(model: model, featureID: "qr")

            FeatureModuleCard(model: model, featureID: "clipboardocr")

            FeatureModuleCard(model: model, featureID: "hotkeycheatsheet")

            FeatureModuleCard(model: model, featureID: "power") {
                PowerTestRows(model: model)
            }
        }
    }
}

// MARK: - 文字片段库入口

/// 片段可能有几十条，全部铺在设置卡片里会把页面撑得很长。
/// 这里只留「有多少条 + 一个管理按钮」，编辑放进独立的管理窗口。
private struct SnippetLibraryEntry: View {
    @State private var count: Int = SnippetStore.shared.snippets.count

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteNotice(
                text: IadenteL10n.t(
                    "用途：把常写的内容（邮箱、地址、签名、常用回复…）存成模板。按快捷键唤起面板，输入关键字筛选，回车后 macall 会自动替你粘贴到当前输入框。",
                    "Store text you type often (email, address, signature, canned replies). Summon the panel, filter, hit Return and macall pastes it for you."),
                icon: "lightbulb.fill",
                colors: IadenteTheme.aboutColors
            )

            IadenteControlRow(
                IadenteL10n.t("片段库", "Snippet library"),
                subtitle: IadenteL10n.t(
                    "已保存 \(count) 条片段。新建、编辑与删除都在管理窗口里完成。",
                    "\(count) snippets saved. Create, edit and delete them in the manager."),
                icon: "text.quote",
                colors: IadenteTheme.aboutColors
            ) {
                Button(IadenteL10n.t("管理…", "Manage…")) {
                    SnippetsManagerWindowController.shared.show { count = SnippetStore.shared.snippets.count }
                }
                .controlSize(.small)
                .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.aboutColors))
            }
        }
        .onAppear { count = SnippetStore.shared.snippets.count }
    }
}

// MARK: - 电源动作实测入口

/// 锁屏 / 睡眠 / 熄屏 / 深色模式都属于「不按快捷键就没法验证」的动作，
/// 这里给出直接触发按钮（危险动作二次确认）。
private struct PowerTestRows: View {
    @ObservedObject var model: SettingsModel
    @State private var confirming: PowerAction? = nil

    private enum PowerAction: String, Identifiable {
        case lock = "power.lock"
        case sleep = "power.sleep"
        case displaySleep = "power.displaySleep"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .lock: return IadenteL10n.t("锁屏", "Lock screen")
            case .sleep: return IadenteL10n.t("系统睡眠", "System sleep")
            case .displaySleep: return IadenteL10n.t("熄屏", "Display sleep")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("切换深色模式", "Toggle dark mode"),
                subtitle: IadenteL10n.t(
                    "立即在浅色 / 深色之间切换，可用来确认该动作是否生效。",
                    "Switch between light and dark right now to verify the action."),
                icon: "circle.lefthalf.filled",
                colors: IadenteTheme.aboutColors
            ) {
                Button(IadenteL10n.t("立即切换", "Toggle")) { run("power.toggleDark") }
                    .controlSize(.small)
                    .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.aboutColors))
            }

            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("电源动作实测", "Test power actions"),
                subtitle: IadenteL10n.t(
                    "点击会真的执行对应动作，请先保存好手上的工作。",
                    "These really do execute — save your work first."),
                icon: "bolt.badge.clock",
                colors: IadenteTheme.aboutColors
            ) {
                HStack(spacing: 6) {
                    Button(PowerAction.lock.title) { confirming = .lock }
                        .controlSize(.small)
                    Button(PowerAction.displaySleep.title) { confirming = .displaySleep }
                        .controlSize(.small)
                    Button(PowerAction.sleep.title) { confirming = .sleep }
                        .controlSize(.small)
                }
            }
        }
        .alert(item: $confirming) { action in
            Alert(
                title: Text(IadenteL10n.t("执行「\(action.title)」？", "Run \(action.title)?")),
                message: Text(IadenteL10n.t(
                    "该动作会立即改变系统状态。",
                    "This will change the system state immediately.")),
                primaryButton: .destructive(Text(IadenteL10n.t("执行", "Run"))) {
                    run(action.rawValue)
                },
                secondaryButton: .cancel(Text(IadenteL10n.t("取消", "Cancel")))
            )
        }
    }

    private func run(_ action: String) {
        model.registry.feature("power")?.handle(action: action)
    }
}

// MARK: - 工具箱图标与面板内容管理

/// 管理工具箱状态栏图标的显隐，以及面板里小工具的顺序与显隐。
/// 数据全部来自 `toolboxOrder` / `toolboxHidden` / `showToolboxIcon`，
/// 不触碰各工具自己的总开关（总开关在各自卡片里）。
private struct ToolboxManagerCard: View {
    @Default(.showToolboxIcon) private var showIcon
    @Default(.toolboxOrder) private var order
    @Default(.toolboxHidden) private var hidden

    var body: some View {
        IadenteCard(
            IadenteL10n.t("工具箱图标", "Toolbox icon"),
            subtitle: IadenteL10n.t(
                "独立的状态栏图标，点开列出所有小工具。下面调整面板里的工具顺序与显隐。",
                "A separate menu-bar icon that lists every tool. Reorder and show/hide them below."),
            icon: "toolbox.fill",
            colors: IadenteTheme.aboutColors,
            trailing: {
                Toggle("", isOn: $showIcon)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(IadenteTheme.aboutColors.first ?? IadenteTheme.jade)
            },
            content: {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, tool in
                        toolRow(tool, index: index)
                        if index < order.count - 1 {
                            IadenteRowDivider().padding(.leading, 46)
                        }
                    }
                }
            }
        )
    }

    private func toolRow(_ tool: ToolboxTool, index: Int) -> some View {
        HStack(spacing: 12) {
            ReorderControl(
                isFirst: index == 0,
                isLast: index == order.count - 1,
                onUp: { move(tool, by: -1) },
                onDown: { move(tool, by: 1) })
            IadenteIconBadge(icon: tool.icon, colors: IadenteTheme.aboutColors, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)
                Text(tool.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button(action: { toggleHidden(tool) }) {
                Image(systemName: hidden.contains(tool) ? "eye.slash" : "eye")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        hidden.contains(tool)
                            ? Color.secondary
                            : (IadenteTheme.aboutColors.first ?? .accentColor))
            }
            .buttonStyle(.plain)
            .help(hidden.contains(tool)
                  ? IadenteL10n.t("已在面板中隐藏，点击恢复", "Hidden — click to show")
                  : IadenteL10n.t("在面板中显示，点击隐藏", "Shown — click to hide"))
        }
        .padding(.vertical, 4)
        .opacity(hidden.contains(tool) ? 0.5 : 1)
    }

    private func move(_ tool: ToolboxTool, by delta: Int) {
        guard let i = order.firstIndex(of: tool) else { return }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        var next = order
        next.swapAt(i, j)
        order = next
    }

    private func toggleHidden(_ tool: ToolboxTool) {
        var h = hidden
        if let idx = h.firstIndex(of: tool) {
            h.remove(at: idx)
        } else {
            h.append(tool)
        }
        hidden = h
    }
}

// MARK: - 键盘清洁倒计时

private struct CleanCountdownRow: View {
    @Default(.cleanCountdownSeconds) private var seconds
    @Default(.cleanAutoDisplaySleep) private var autoSleep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()
            IadenteControlRow(
                IadenteL10n.t("自动解锁倒计时", "Auto-unlock countdown"),
                subtitle: IadenteL10n.t(
                    "锁定后到自动解锁的秒数。清洁期间也可随时用鼠标点「立即结束」。",
                    "Seconds until auto-unlock. You can also click End now with the mouse any time."),
                icon: "timer",
                colors: IadenteTheme.aboutColors
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { Double(seconds) },
                            set: { seconds = Int($0) }),
                        in: 5...600,
                        step: 5
                    )
                    .frame(width: 150)
                    Text("\(seconds)s")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }

            IadenteRowDivider()
            IadenteControlRow(
                IadenteL10n.t("进入即自动熄屏", "Auto display-off on start"),
                subtitle: IadenteL10n.t(
                    "开启后，进入清洁模式会自动熄屏（背光关闭），便于看清屏幕灰尘；移动鼠标唤醒后点「立即结束」。",
                    "On entry the display turns off (backlight off) so screen dust is visible; move the mouse to wake and click End now."),
                icon: "powersleep",
                colors: IadenteTheme.aboutColors
            ) {
                Toggle("", isOn: $autoSleep)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}
