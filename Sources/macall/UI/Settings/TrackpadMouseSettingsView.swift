import AppKit
import SwiftUI

/// 触控板与鼠标设置页（独立一级 tab，不再挂在「屏幕」里）。
/// 含两块：触控板手势调节（touchpadControl）+ 鼠标优化（mouseOptimize）。
/// 两者互不干扰：鼠标优化只改鼠标滚轮，绝不碰触控板。
struct TrackpadMouseSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        IadenteSettingsPage {
            FeatureModuleCard(model: model, featureID: "touchpadControl", showsHotkeys: false) {
                touchpadGestureSettings
            }

            FeatureModuleCard(model: model, featureID: "mouseOptimize", showsHotkeys: false) {
                mouseOptimizeSettings
            }
        }
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
                "MOS 同款平滑引擎（方向感知累积 + 指数缓动 + 曲线滤波，CVDisplayLink 帧同步）。下方可微调步长 / 速度 / 时长。",
                "The MOS smoothing engine (direction-aware accumulation + exponential easing + curve filtering, display-link synced). Tune step / speed / duration below."),
            icon: "waveform.path",
            colors: IadenteTheme.dashboardColors,
            isOn: Binding(
                get: { model.config.mouseSmoothScroll },
                set: { model.config.mouseSmoothScroll = $0; model.save() }
            )
        )

        // —— 高级（仅平滑开启时才有意义，但仍可预设）——
        IadenteControlRow(
            IadenteL10n.t("滚动步长", "Step"),
            subtitle: IadenteL10n.t(
                "低于该幅度的滚轮 tick 归一抬到该值（去抖 + 提速）。默认 33.6，与 MOS 一致。",
                "Wheel ticks below this magnitude are raised to it (de-jitter + speed). Default 33.6, same as MOS."),
            icon: "ruler",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: stepBinding, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Stepper("", value: stepBinding, in: 1...100, step: 0.1)
                    .labelsHidden()
            }
            .frame(width: 120)
        }

        IadenteControlRow(
            IadenteL10n.t("滚动速度", "Speed"),
            subtitle: IadenteL10n.t(
                "滚轮速度整体倍率：1 = 原速，>1 更快，<1 更慢；默认 2.70，与 MOS 一致。",
                "Overall wheel-speed multiplier: 1 = native, >1 faster, <1 slower; default 2.70, same as MOS."),
            icon: "gauge",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: speedBinding, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Stepper("", value: speedBinding, in: 0.1...10, step: 0.1)
                    .labelsHidden()
            }
            .frame(width: 120)
        }

        IadenteControlRow(
            IadenteL10n.t("滚动时长", "Duration"),
            subtitle: IadenteL10n.t(
                "指数缓动时长参数：越大越顺滑、惯性滑行越久；默认 4.35，与 MOS 一致。",
                "Exponential-ease duration: larger = smoother & longer glide; default 4.35, same as MOS."),
            icon: "timer",
            colors: IadenteTheme.dashboardColors
        ) {
            HStack(spacing: 6) {
                TextField("", value: durationBinding, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Stepper("", value: durationBinding, in: 0.1...8, step: 0.05)
                    .labelsHidden()
            }
            .frame(width: 120)
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
                "以上选项默认全部关闭，仅当你打开总开关并勾选某项后才生效。鼠标优化只拦截鼠标事件，触控板滚动照常，互不干扰。需辅助功能权限。",
                "All options are off by default and only take effect once the master switch and the item itself are on. Mouse optimization intercepts only mouse events; trackpad scrolling is untouched. Needs Accessibility."),
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

    private var stepBinding: Binding<Double> {
        Binding(
            get: { model.config.mouseScrollStep },
            set: { v in
                guard v.isFinite, v > 0 else { return }
                model.config.mouseScrollStep = min(100, max(1, (v * 10).rounded() / 10))
                model.save()
            }
        )
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { model.config.mouseScrollSpeed },
            set: { v in
                guard v.isFinite, v > 0 else { return }
                model.config.mouseScrollSpeed = min(10, max(0.1, (v * 100).rounded() / 100))
                model.save()
            }
        )
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { model.config.mouseScrollDuration },
            set: { v in
                guard v.isFinite, v > 0 else { return }
                model.config.mouseScrollDuration = min(8, max(0.1, (v * 100).rounded() / 100))
                model.save()
            }
        )
    }

    private func edgeActionLabel(_ a: TouchpadEdgeAction) -> String {
        switch a {
        case .brightness: return IadenteL10n.t("亮度", "Brightness")
        case .volume: return IadenteL10n.t("音量", "Volume")
        case .off: return IadenteL10n.t("关闭", "Off")
        }
    }
}
