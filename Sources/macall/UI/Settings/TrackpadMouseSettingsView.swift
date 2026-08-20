import AppKit
import SwiftUI

/// 触控板与鼠标设置页（独立一级 tab，不再挂在「屏幕」里）。
/// 含两块：触控板手势调节（touchpadControl）+ 鼠标优化（mouseOptimize）。
/// 两者互不干扰：鼠标优化只改鼠标滚轮 / 侧键，绝不碰触控板。
struct TrackpadMouseSettingsView: View {
    @ObservedObject var model: SettingsModel

    /// 逐 App 例外编辑：当前选中的（待添加）App bundleID。
    @State private var selectedAppBundle: String? = nil
    /// 正在运行、可作为例外添加的 App 列表。
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        IadenteSettingsPage {
            FeatureModuleCard(model: model, featureID: "touchpadControl", showsHotkeys: false) {
                touchpadGestureSettings
            }

            FeatureModuleCard(model: model, featureID: "mouseOptimize", showsHotkeys: false) {
                mouseOptimizeSettings
            }
        }
        .onAppear(perform: refreshApps)
    }

    // MARK: - 触控板手势调节

    @ViewBuilder
    private var touchpadGestureSettings: some View {
        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("拖动灵敏度", "Drag sensitivity"),
            subtitle: IadenteL10n.t(
                "手指上下拖动时调节的快慢。数值越小越不灵敏（需更大位移才调同样多）；默认 0.6。",
                "How fast a vertical drag changes the value. Lower = less sensitive (needs more travel); default 0.6."),
            icon: "dial.medium.fill",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: dragSensitivity, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper("", value: dragSensitivity, in: 0.2...1.5, step: 0.05)
                    .labelsHidden()
            }
            .frame(width: 190)
        }

        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("起手区", "Edge start zone"),
            subtitle: IadenteL10n.t(
                "手指必须落在最外 N% 才开始算边缘滑入。越小越严格（必须贴最外缘），越大越宽松；默认 6%。",
                "Finger must land in the outermost N% to count as an edge swipe. Lower = stricter (right at the edge), higher = looser; default 6%."),
            icon: "arrow.down.and.line.horizontal.and.arrow.up",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: startZonePercent, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text("%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper("", value: startZonePercent, in: 2...15, step: 1)
                    .labelsHidden()
            }
            .frame(width: 190)
        }

        IadenteControlRow(
            IadenteL10n.t("向内行程", "Inward travel"),
            subtitle: IadenteL10n.t(
                "起手后需向内滑动多少才锁定调节。越大越不容易误触，但需要更明显的滑动；默认 15%。",
                "How far the finger must slide inward before adjusting locks in. Higher = fewer accidental triggers but needs a clearer swipe; default 15%."),
            icon: "arrow.left.to.line.compact",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: minTravelPercent, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text("%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper("", value: minTravelPercent, in: 5...30, step: 1)
                    .labelsHidden()
            }
            .frame(width: 190)
        }

        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("左边缘", "Left edge"),
            subtitle: IadenteL10n.t(
                "触控板最左约 25% 区域触发的动作。",
                "Action triggered on the leftmost ~25% of the trackpad."),
            icon: "arrow.left.to.line",
            colors: IadenteTheme.dashboardColors
        ) {
            Picker("", selection: Binding(
                get: { model.config.touchpadLeftAction },
                set: { model.config.touchpadLeftAction = $0; model.save() }
            )) {
                ForEach(TouchpadEdgeAction.allCases, id: \.self) { a in
                    Text(edgeActionLabel(a)).tag(a)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }

        IadenteControlRow(
            IadenteL10n.t("右边缘", "Right edge"),
            subtitle: IadenteL10n.t(
                "触控板最右约 25% 区域触发的动作。",
                "Action triggered on the rightmost ~25% of the trackpad."),
            icon: "arrow.right.to.line",
            colors: IadenteTheme.dashboardColors
        ) {
            Picker("", selection: Binding(
                get: { model.config.touchpadRightAction },
                set: { model.config.touchpadRightAction = $0; model.save() }
            )) {
                ForEach(TouchpadEdgeAction.allCases, id: \.self) { a in
                    Text(edgeActionLabel(a)).tag(a)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }

        IadenteRowDivider()

        IadenteSettingToggle(
            IadenteL10n.t("调节时触觉反馈", "Haptic feedback"),
            subtitle: IadenteL10n.t(
                "开始调节、以及数值每跨越约 2% 时给出「咔哒」逐级反馈。",
                "A tap when adjustment starts, plus a stepped 'click' every ~2% of travel."),
            icon: "waveform",
            colors: IadenteTheme.dashboardColors,
            isOn: Binding(
                get: { model.config.touchpadHaptic },
                set: { model.config.touchpadHaptic = $0; model.save() }
            )
        )

        IadenteNotice(
            text: IadenteL10n.t(
                "该功能依赖 macOS 私有框架 MultitouchSupport，桥接在用户本机完成。若开启后无反应，请查看日志 [touchpad]。",
                "This relies on the private MultitouchSupport framework, bridged on your Mac. If it does nothing after enabling, check the [touchpad] log."),
            icon: "info.circle.fill",
            colors: IadenteTheme.dashboardColors
        )
    }

    // MARK: - 鼠标优化

    @ViewBuilder
    private var mouseOptimizeSettings: some View {
        // —— 基础 ——
        IadenteRowDivider()

        IadenteSettingToggle(
            IadenteL10n.t("滚轮独立反转", "Invert scroll direction"),
            subtitle: IadenteL10n.t(
                "只反转鼠标滚轮方向，不影响触控板（系统设置里两者是绑定的，这里解耦）。",
                "Invert only the mouse wheel, leaving the trackpad untouched (the system binds both together)."),
            icon: "arrow.up.arrow.down.circle",
            colors: IadenteTheme.dashboardColors,
            isOn: Binding(
                get: { model.config.mouseScrollInvert },
                set: { model.config.mouseScrollInvert = $0; model.save() }
            )
        )

        IadenteRowDivider()

        IadenteSettingToggle(
            IadenteL10n.t("平滑滚动", "Smooth scrolling"),
            subtitle: IadenteL10n.t(
                "带惯性滑行尾迹的参数化平滑引擎（类似触控板的减速过程）。下方可微调最短步长 / 速度增益 / 平滑时长。",
                "A parametrised inertial smoothing engine (like the trackpad's deceleration glide). Tune min step / speed gain / smoothing duration below."),
            icon: "waveform.path",
            colors: IadenteTheme.dashboardColors,
            isOn: Binding(
                get: { model.config.mouseSmoothScroll },
                set: { model.config.mouseSmoothScroll = $0; model.save() }
            )
        )

        // —— 高级（仅平滑开启时才有意义，但仍可预设）——
        IadenteControlRow(
            IadenteL10n.t("最短步长", "Min step"),
            subtitle: IadenteL10n.t(
                "小于该幅度的微动先累积、超过才刷新，用来滤掉生硬的小跳变；默认 1.0。",
                "Ticks smaller than this accumulate first, then flush — filters out tiny jitters; default 1.0."),
            icon: "ruler",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: minStepBinding, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Stepper("", value: minStepBinding, in: 0.1...5, step: 0.1)
                    .labelsHidden()
            }
            .frame(width: 120)
        }

        IadenteControlRow(
            IadenteL10n.t("速度增益", "Speed gain"),
            subtitle: IadenteL10n.t(
                "滚轮速度整体倍率：1 = 原速，>1 更快，<1 更慢；默认 1.0。",
                "Overall wheel-speed multiplier: 1 = native, >1 faster, <1 slower; default 1.0."),
            icon: "gauge",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: speedGainBinding, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Stepper("", value: speedGainBinding, in: 0.5...3, step: 0.1)
                    .labelsHidden()
            }
            .frame(width: 120)
        }

        IadenteControlRow(
            IadenteL10n.t("平滑时长", "Smoothing duration"),
            subtitle: IadenteL10n.t(
                "惯性滑行尾迹持续的时间（秒）：越大越顺滑、滑行越久；默认 0.18。",
                "How long the inertial glide lasts (seconds): larger = smoother & longer glide; default 0.18."),
            icon: "timer",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: smoothDurationBinding, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text("s")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper("", value: smoothDurationBinding, in: 0.05...0.6, step: 0.01)
                    .labelsHidden()
            }
            .frame(width: 130)
        }

        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("加速键", "Accel key"),
            subtitle: IadenteL10n.t(
                "滚动时按住此修饰键，临时把速度增益再翻倍。",
                "Hold this modifier while scrolling to temporarily double the speed gain."),
            icon: "bolt.fill",
            colors: IadenteTheme.dashboardColors
        ) {
            modifierPicker(Binding(
                get: { model.config.mouseAccelKey },
                set: { model.config.mouseAccelKey = $0; model.save() }
            ))
            .frame(width: 70)
        }

        IadenteControlRow(
            IadenteL10n.t("转换键", "Convert key"),
            subtitle: IadenteL10n.t(
                "滚动时按住此修饰键，临时反转方向。",
                "Hold this modifier while scrolling to temporarily reverse direction."),
            icon: "arrow.left.arrow.right.circle",
            colors: IadenteTheme.dashboardColors
        ) {
            modifierPicker(Binding(
                get: { model.config.mouseConvertKey },
                set: { model.config.mouseConvertKey = $0; model.save() }
            ))
            .frame(width: 70)
        }

        IadenteControlRow(
            IadenteL10n.t("禁用键", "Disable key"),
            subtitle: IadenteL10n.t(
                "滚动时按住此修饰键，临时关闭平滑（原样透传）。",
                "Hold this modifier while scrolling to temporarily disable smoothing (pass through)."),
            icon: "pause.circle",
            colors: IadenteTheme.dashboardColors
        ) {
            modifierPicker(Binding(
                get: { model.config.mouseDisableKey },
                set: { model.config.mouseDisableKey = $0; model.save() }
            ))
            .frame(width: 70)
        }

        // —— 侧键绑定 ——
        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("侧键 X1（后退）", "Side button X1 (Back)"),
            subtitle: IadenteL10n.t(
                "X1 侧键绑定的 macall 动作；触发即派发，相当于按了对应快捷键。选「无」则透传。",
                "Action bound to the X1 side button; pressing it dispatches that action. None = pass through."),
            icon: "mouse.fill",
            colors: IadenteTheme.dashboardColors
        ) {
            sideActionPicker(Binding(
                get: { model.config.mouseSideAction1 },
                set: { model.config.mouseSideAction1 = $0; model.save() }
            ))
            .frame(width: 150)
        }

        IadenteControlRow(
            IadenteL10n.t("侧键 X2（前进）", "Side button X2 (Forward)"),
            subtitle: IadenteL10n.t(
                "X2 侧键绑定的 macall 动作；同样触发即派发。选「无」则透传。",
                "Action bound to the X2 side button; also dispatches on press. None = pass through."),
            icon: "mouse.fill",
            colors: IadenteTheme.dashboardColors
        ) {
            sideActionPicker(Binding(
                get: { model.config.mouseSideAction2 },
                set: { model.config.mouseSideAction2 = $0; model.save() }
            ))
            .frame(width: 150)
        }

        // —— 例外（逐 App 三态）——
        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("逐 App 例外", "Per-app overrides"),
            subtitle: IadenteL10n.t(
                "给某个 App 单独覆盖全局行为：强制平滑 / 强制反转 / 白名单豁免（完全不优化）。",
                "Override the global behaviour per app: force smooth / force invert / whitelist (fully off)."),
            icon: "app.badge.checkmark",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                Picker("", selection: $selectedAppBundle) {
                    Text(IadenteL10n.t("选择应用…", "Choose app…")).tag(String?.none)
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Text(app.localizedName ?? app.bundleIdentifier ?? "?")
                            .tag(app.bundleIdentifier as String?)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Button(IadenteL10n.t("添加", "Add")) { addSelectedApp() }
                    .controlSize(.small)
                    .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.dashboardColors))
            }
        }

        IadenteRowDivider()

        // 例外列表（按 bundleID 排序，保证稳定顺序）。
        let entries = model.config.mouseAppOverrides.keys.sorted()
        if entries.isEmpty {
            Text(IadenteL10n.t("暂无例外。点上方「添加」把当前前台 / 选中 App 加进来。", "No overrides yet. Use “Add” above to include the frontmost / selected app."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(entries, id: \.self) { bid in
                HStack(spacing: 8) {
                    Image(nsImage: appIcon(bid))
                        .resizable()
                        .frame(width: 18, height: 18)
                        .cornerRadius(4)
                    Text(appName(bid))
                        .font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { model.config.mouseAppOverrides[bid] ?? .smooth },
                        set: { model.config.mouseAppOverrides[bid] = $0; model.save() }
                    )) {
                        ForEach(MouseAppOverride.allCases, id: \.self) { o in
                            Text(o.title).tag(o)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    Button {
                        model.config.mouseAppOverrides.removeValue(forKey: bid)
                        model.save()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(IadenteL10n.t("移除该例外", "Remove this override"))
                }
                .padding(.vertical, 2)
            }
        }

        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("光标加速度", "Cursor acceleration"),
            subtitle: IadenteL10n.t(
                "macall 不改系统参数（避免与系统冲突）。点此直接跳到系统鼠标设置，自行调节加速度。",
                "macall does not touch system parameters (to avoid conflicts). Jump to the system mouse panel to tune acceleration."),
            icon: "cursorarrow.motionlines",
            colors: IadenteTheme.dashboardColors
        ) {
            Button(IadenteL10n.t("打开系统设置", "Open System Settings")) {
                Permissions.openMouseSettings()
            }
            .controlSize(.small)
            .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.dashboardColors))
        }

        IadenteNotice(
            text: IadenteL10n.t(
                "以上选项默认全部关闭，仅当你打开总开关并勾选某项后才生效。鼠标优化只拦截鼠标事件，触控板滚动照常，互不干扰。需辅助功能 + 输入监控权限。",
                "All options are off by default and only take effect once the master switch and the item itself are on. Mouse optimization intercepts only mouse events; trackpad scrolling is untouched. Needs Accessibility + Input Monitoring."),
            icon: "info.circle.fill",
            colors: IadenteTheme.dashboardColors
        )
    }

    // MARK: - 绑定辅助

    /// 拖动灵敏度（0.2…1.5，0.05 步进）数字编辑：输入吸附到 0.05 的倍数并 clamp。
    private var dragSensitivity: Binding<Double> {
        Binding(
            get: { model.config.touchpadSensitivity },
            set: { v in
                guard v.isFinite else { return }
                let step = 0.05
                let snapped = (v / step).rounded() * step
                model.config.touchpadSensitivity = min(1.5, max(0.2, snapped))
                model.save()
            }
        )
    }

    /// 起手区（配置存 0.02…0.15）以整数百分比编辑（2…15）。
    private var startZonePercent: Binding<Double> {
        Binding(
            get: { model.config.touchpadStartZone * 100 },
            set: { v in
                let p = v.isFinite ? min(15, max(2, v.rounded())) : (model.config.touchpadStartZone * 100)
                model.config.touchpadStartZone = p / 100
                model.save()
            }
        )
    }

    /// 向内行程（配置存 0.05…0.30）以整数百分比编辑（5…30）。
    private var minTravelPercent: Binding<Double> {
        Binding(
            get: { model.config.touchpadMinTravel * 100 },
            set: { v in
                let p = v.isFinite ? min(30, max(5, v.rounded())) : (model.config.touchpadMinTravel * 100)
                model.config.touchpadMinTravel = p / 100
                model.save()
            }
        )
    }

    private var minStepBinding: Binding<Double> {
        Binding(
            get: { model.config.mouseMinStep },
            set: { v in
                guard v.isFinite, v > 0 else { return }
                model.config.mouseMinStep = min(5, max(0.1, (v * 10).rounded() / 10))
                model.save()
            }
        )
    }

    private var speedGainBinding: Binding<Double> {
        Binding(
            get: { model.config.mouseSpeedGain },
            set: { v in
                guard v.isFinite, v > 0 else { return }
                model.config.mouseSpeedGain = min(3, max(0.5, (v * 100).rounded() / 100))
                model.save()
            }
        )
    }

    private var smoothDurationBinding: Binding<Double> {
        Binding(
            get: { model.config.mouseSmoothDuration },
            set: { v in
                guard v.isFinite, v > 0 else { return }
                model.config.mouseSmoothDuration = min(0.6, max(0.05, (v * 100).rounded() / 100))
                model.save()
            }
        )
    }

    private func modifierPicker(_ selection: Binding<MouseModifierKey>) -> some View {
        Picker("", selection: selection) {
            ForEach(MouseModifierKey.allCases, id: \.self) { k in
                Text(k.title).tag(k)
            }
        }
        .labelsHidden()
    }

    private func sideActionPicker(_ selection: Binding<MouseSideAction>) -> some View {
        Picker("", selection: selection) {
            ForEach(MouseSideAction.allCases, id: \.self) { a in
                Text(a.title).tag(a)
            }
        }
        .labelsHidden()
    }

    // MARK: - 逐 App 例外辅助

    private func refreshApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
    }

    private func addSelectedApp() {
        guard let bid = selectedAppBundle, !bid.isEmpty else { return }
        model.config.mouseAppOverrides[bid] = .smooth
        model.save()
        selectedAppBundle = nil
    }

    private func appName(_ bid: String) -> String {
        if let app = runningApps.first(where: { $0.bundleIdentifier == bid }) {
            return app.localizedName ?? bid
        }
        return bid
    }

    private func appIcon(_ bid: String) -> NSImage {
        if let app = runningApps.first(where: { $0.bundleIdentifier == bid }),
           let icon = app.icon {
            return icon
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    private func edgeActionLabel(_ a: TouchpadEdgeAction) -> String {
        switch a {
        case .brightness: return IadenteL10n.t("亮度", "Brightness")
        case .volume: return IadenteL10n.t("音量", "Volume")
        case .off: return IadenteL10n.t("关闭", "Off")
        }
    }
}
