import SwiftUI

/// 窗口与分屏设置页。
///
/// 每个窗口相关模块各占一张 `FeatureModuleCard`：卡片右上角是模块总开关，
/// 卡片内是该模块的子功能（快捷键行，每行行尾一个子开关）+ 模块专属设置。
/// 全 App 所有设置页都用这一套结构，排序与开关样式完全一致。
struct WindowSnapSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        IadenteSettingsPage {
            if !Permissions.isAccessibilityWorking() {
                AccessibilityPermissionBanner()
            }

            // 1) 窗口吸附（含分屏间距与布局速览）
            FeatureModuleCard(model: model, featureID: "windowSnap") {
                snapExtras
            }

            // 2) 显示桌面 / 隐藏其他
            FeatureModuleCard(model: model, featureID: "hideWindows")

            // 3) 跨屏移动
            FeatureModuleCard(model: model, featureID: "displayMove")

            // 4) 窗口置顶
            FeatureModuleCard(model: model, featureID: "alwaysontop") {
                AlwaysOnTopTestRow(model: model)
            }

            // 5) 窗口切换（含触发键预设）
            FeatureModuleCard(model: model, featureID: "switcher") {
                SwitcherTriggerRow(model: model)
            }

            // 6) 边缘吸附分屏（拖拽触发，可在下方设置边缘默认分屏 / 选择器）
            FeatureModuleCard(model: model, featureID: "edgeSnap") {
                EdgeSnapOptionsRow(model: model)
            }

            // 7) Dock 图标反转
            FeatureModuleCard(model: model, featureID: "dockToggle") {
                DockToggleBehaviorRow(model: model)
            }

            // 8) Dock 悬停预览
            FeatureModuleCard(model: model, featureID: "preview")
        }
    }

    // MARK: - 吸附模块专属设置

    @ViewBuilder
    private var snapExtras: some View {
        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("分屏间距", "Snap gap"),
            subtitle: IadenteL10n.t(
                "吸附后相邻窗口之间的留白。",
                "Padding between adjacent windows after snapping."),
            icon: "arrow.left.and.right.square",
            colors: IadenteTheme.generalColors
        ) {
            Text("\(Int(model.config.gap)) pt")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }

        Slider(
            value: Binding(
                get: { model.config.gap },
                set: {
                    model.config.gap = $0
                    model.save()
                }
            ),
            in: 0...24,
            step: 2
        )

        IadenteRowDivider()

        Text(IadenteL10n.t("支持的布局", "Supported layouts"))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)

        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ], spacing: 12) {
            LayoutPreview(kind: .leftHalf, label: IadenteL10n.t("左半屏", "Left Half"))
            LayoutPreview(kind: .rightHalf, label: IadenteL10n.t("右半屏", "Right Half"))
            LayoutPreview(kind: .topHalf, label: IadenteL10n.t("上半屏", "Top Half"))
            LayoutPreview(kind: .bottomHalf, label: IadenteL10n.t("下半屏", "Bottom Half"))
            LayoutPreview(kind: .topLeft, label: IadenteL10n.t("左上", "Top Left"))
            LayoutPreview(kind: .topRight, label: IadenteL10n.t("右上", "Top Right"))
            LayoutPreview(kind: .bottomLeft, label: IadenteL10n.t("左下", "Bottom Left"))
            LayoutPreview(kind: .bottomRight, label: IadenteL10n.t("右下", "Bottom Right"))
            LayoutPreview(kind: .leftThird, label: IadenteL10n.t("左 1/3", "Left Third"))
            LayoutPreview(kind: .centerThird, label: IadenteL10n.t("中 1/3", "Center Third"))
            LayoutPreview(kind: .rightThird, label: IadenteL10n.t("右 1/3", "Right Third"))
            LayoutPreview(kind: .leftTwoThirds, label: IadenteL10n.t("左 2/3", "Left 2/3"))
            LayoutPreview(kind: .rightTwoThirds, label: IadenteL10n.t("右 2/3", "Right 2/3"))
            LayoutPreview(kind: .maximize, label: IadenteL10n.t("最大化", "Maximize"))
            LayoutPreview(kind: .center, label: IadenteL10n.t("居中", "Center"))
        }
    }
}

// MARK: - 辅助功能权限横幅（页面级共用）

struct AccessibilityPermissionBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            IadenteIconBadge(
                icon: "exclamationmark.triangle.fill",
                colors: [IadenteTheme.amber, IadenteTheme.gold],
                size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(IadenteL10n.t("需要辅助功能权限", "Accessibility permission required"))
                    .font(.system(size: 12.5, weight: .semibold))
                Text(IadenteL10n.t(
                    "移动、缩放与读取窗口位置都依赖辅助功能权限，未授予时窗口类功能会静默失效。",
                    "Moving, resizing and reading window frames all need Accessibility access."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(IadenteL10n.t("去授予", "Grant")) {
                Permissions.openAccessibilitySettings()
            }
            .controlSize(.small)
            .buttonStyle(IadenteActionButtonStyle(colors: [IadenteTheme.amber, IadenteTheme.gold]))
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(IadenteTheme.amber.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(IadenteTheme.amber.opacity(0.24))
        }
    }
}

// MARK: - Dock 图标反转行为

/// 两种互斥行为：点击已激活 App 的 Dock 图标时，要么最小化全部窗口，要么隐藏整个 App。
private struct DockToggleBehaviorRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteSettingToggle(
                IadenteL10n.t("点按 Dock 图标最小化", "Minimize on Dock click"),
                subtitle: IadenteL10n.t(
                    "点击已激活 App 的 Dock 图标时，将其全部窗口最小化到 Dock；再次点击恢复。",
                    "Click an active app's Dock icon to minimize all its windows; click again to restore."),
                icon: "minus.square",
                colors: IadenteTheme.generalColors,
                isOn: minimizeBinding
            )

            IadenteSettingToggle(
                IadenteL10n.t("点按 Dock 图标隐藏 App", "Hide app on Dock click"),
                subtitle: IadenteL10n.t(
                    "点击已激活 App 的 Dock 图标时，隐藏整个 App（效果等同 ⌘H）；再次点击恢复。",
                    "Click an active app's Dock icon to hide the whole app (same as ⌘H); click again to restore."),
                icon: "eye.slash",
                colors: IadenteTheme.generalColors,
                isOn: hideBinding
            )
        }
    }

    private var minimizeBinding: Binding<Bool> {
        Binding(
            get: { model.config.dockToggleBehavior == .minimize },
            set: { on in
                guard on else { return }
                model.config.dockToggleBehavior = .minimize
                model.save()
            }
        )
    }

    private var hideBinding: Binding<Bool> {
        Binding(
            get: { model.config.dockToggleBehavior == .hideApp },
            set: { on in
                guard on else { return }
                model.config.dockToggleBehavior = .hideApp
                model.save()
            }
        )
    }
}

// MARK: - 边缘吸附分屏选项

/// 边缘吸附分屏的专属设置：左 / 右边缘各自默认分屏比例（选择器关闭时生效）、
/// 「边缘分屏选择器」开关（开启后每次拖到边缘弹出选择器：三分屏 / 两分屏 / (1/3·2/3) / (2/3·1/3)，每块内小方块可选）。
private struct EdgeSnapOptionsRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            HStack(spacing: 16) {
                sidePicker(title: IadenteL10n.t("左边缘默认", "Left edge default"),
                           selection: leftBinding, disabled: selectorOn)
                Spacer(minLength: 0)
                sidePicker(title: IadenteL10n.t("右边缘默认", "Right edge default"),
                           selection: rightBinding, disabled: selectorOn)
            }

            IadenteSettingToggle(
                IadenteL10n.t("边缘分屏选择器", "Edge snap selector"),
                subtitle: IadenteL10n.t(
                    "关闭时拖到边缘直接用上方预设分屏；开启时每次拖到边缘弹出选择器：三分屏 / 两分屏 / (1/3·2/3) / (2/3·1/3)，每块内的小方块都可单独选中。",
                    "Off: drag to an edge snaps to the preset above. On: a picker appears each time with 4 blocks (3-split / 2-split / 1/3·2/3 / 2/3·1/3); every inner tile is selectable."),
                icon: "slider.horizontal.3",
                colors: IadenteTheme.generalColors,
                isOn: selectorBinding
            )
        }
    }

    private func sidePicker(title: String, selection: Binding<EdgeSnapSideLayout>, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                Text("1/3").tag(EdgeSnapSideLayout.third)
                Text("1/2").tag(EdgeSnapSideLayout.half)
                Text("2/3").tag(EdgeSnapSideLayout.twoThirds)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
        }
    }

    private var selectorOn: Bool { model.config.edgeSnapSelectorEnabled }

    private var selectorBinding: Binding<Bool> {
        Binding(
            get: { model.config.edgeSnapSelectorEnabled },
            set: { model.config.edgeSnapSelectorEnabled = $0; model.save() }
        )
    }
    private var leftBinding: Binding<EdgeSnapSideLayout> {
        Binding(
            get: { model.config.edgeSnapLeftLayout },
            set: { model.config.edgeSnapLeftLayout = $0; model.save() }
        )
    }
    private var rightBinding: Binding<EdgeSnapSideLayout> {
        Binding(
            get: { model.config.edgeSnapRightLayout },
            set: { model.config.edgeSnapRightLayout = $0; model.save() }
        )
    }
}

// MARK: - 窗口切换触发键

/// 触发键预设与 `switcher.show` 快捷键是同一份数据：选预设即改写快捷键，
/// 手动改快捷键后这里会自动反推显示为「自定义」。
private struct SwitcherTriggerRow: View {
    @ObservedObject var model: SettingsModel

    private let presets: [SwitcherTriggerPreset] = [
        .optionTab, .commandTab, .custom,
    ]

    private var selectedPreset: SwitcherTriggerPreset {
        guard let c = model.config.hotkeys["switcher.show"]?.toCombo() else { return .optionTab }
        if c == SwitcherTriggerPreset.optionTab.combo { return .optionTab }
        if c == SwitcherTriggerPreset.commandTab.combo { return .commandTab }
        return .custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            IadenteRowDivider()

            Text(IadenteL10n.t("触发键预设", "Trigger preset"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("", selection: Binding<SwitcherTriggerPreset>(
                get: { selectedPreset },
                set: { applyPreset($0) }
            )) {
                ForEach(presets) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(IadenteL10n.t(
                "默认 ⌥Tab。选「接管 ⌘Tab」会拦截系统原生的应用切换。选「自定义」后请用上方那一行的「修改」录制。",
                "Defaults to ⌥Tab. 'Take over ⌘Tab' intercepts the native app switcher. Choose Custom and record via Edit above."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyPreset(_ preset: SwitcherTriggerPreset) {
        guard preset != .custom, let combo = preset.combo else { return }
        model.setHotkey("switcher.show", HotkeySpec(keyCode: combo.keyCode, flags: combo.flags))
    }
}

// MARK: - 窗口置顶实测

/// 置顶作用于「当前最前台窗口」，而设置窗口本身就是最前台窗口，
/// 所以这里给一个延时按钮：点完 3 秒内切到目标窗口即可验证。
private struct AlwaysOnTopTestRow: View {
    @ObservedObject var model: SettingsModel
    @State private var countdown = 0
    @State private var result = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("延时实测", "Delayed test"),
                subtitle: countdown > 0
                    ? IadenteL10n.t("\(countdown) 秒后对当前最前台窗口执行置顶切换…",
                                    "Toggling the frontmost window in \(countdown)s…")
                    : (result.isEmpty
                        ? IadenteL10n.t(
                            "点击后请在 3 秒内切到想置顶的窗口——置顶作用于最前台窗口，而设置窗口本身就是最前台。",
                            "Click, then switch to the target window within 3 seconds.")
                        : result),
                icon: "pin.circle",
                colors: IadenteTheme.generalColors
            ) {
                Button(IadenteL10n.t("3 秒后切换", "Toggle in 3s")) { start() }
                    .controlSize(.small)
                    .disabled(countdown > 0)
                    .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.generalColors))
            }
        }
    }

    private func start() {
        result = ""
        countdown = 3
        tick()
    }

    private func tick() {
        guard countdown > 0 else {
            model.registry.feature("alwaysontop")?.handle(action: "toggle")
            result = IadenteL10n.t("已发出置顶切换指令", "Toggle command sent")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            countdown -= 1
            tick()
        }
    }
}

// MARK: - Layout preview thumbnail (from Macindow)

private struct LayoutPreview: View {
    let kind: SnapKind
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.green.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 52)

                layoutShape
                    .frame(width: 80, height: 52)

                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 4, height: 4)
                    Circle().fill(Color.yellow).frame(width: 4, height: 4)
                    Circle().fill(Color.green).frame(width: 4, height: 4)
                }
                .padding(.top, 4)
                .padding(.leading, 6)
            }
            .frame(width: 80, height: 52)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var layoutShape: some View {
        switch kind {
        case .leftHalf:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 36, height: 44)
                .offset(x: -18, y: 0)
        case .rightHalf:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 36, height: 44)
                .offset(x: 18, y: 0)
        case .topHalf:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 72, height: 20)
                .offset(x: 0, y: -12)
        case .bottomHalf:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 72, height: 20)
                .offset(x: 0, y: 12)
        case .topLeft:
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.80)).frame(width: 34, height: 20)
                .offset(x: -18, y: -12)
        case .topRight:
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.80)).frame(width: 34, height: 20)
                .offset(x: 18, y: -12)
        case .bottomLeft:
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.80)).frame(width: 34, height: 20)
                .offset(x: -18, y: 12)
        case .bottomRight:
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.80)).frame(width: 34, height: 20)
                .offset(x: 18, y: 12)
        case .leftThird:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 22, height: 44)
                .offset(x: -24, y: 0)
        case .centerThird:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 22, height: 44)
                .offset(x: 0, y: 0)
        case .rightThird:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 22, height: 44)
                .offset(x: 24, y: 0)
        case .leftTwoThirds:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 50, height: 44)
                .offset(x: -15, y: 0)
        case .rightTwoThirds:
            Rectangle().fill(Color.primary.opacity(0.80)).frame(width: 50, height: 44)
                .offset(x: 15, y: 0)
        case .maximize:
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.80)).frame(width: 72, height: 44)
        case .center:
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.80)).frame(width: 44, height: 28)
        }
    }
}
