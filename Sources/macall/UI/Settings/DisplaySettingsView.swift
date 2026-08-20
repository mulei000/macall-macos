import AppKit
import CoreGraphics
import SwiftUI

/// 屏幕设置页：触控板与鼠标、显示器控制（DDC）、屏幕放大镜、屏幕取色。
/// 每个模块的总开关都在自己卡片右上角，样式与其他页面完全一致。
struct DisplaySettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        IadenteSettingsPage {
            // —— 触控板与鼠标：把触控板手势调节与新增的鼠标优化归到同一分组 ——
            SectionHeader(
                IadenteL10n.t("触控板与鼠标", "Trackpad & Mouse"),
                subtitle: IadenteL10n.t(
                    "触控板边缘手势与鼠标滚轮 / 侧键优化。两者互不干扰：鼠标优化只改鼠标滚轮，绝不碰触控板。",
                    "Trackpad edge gestures and mouse wheel / side-button tweaks. They never interfere: mouse optimization only touches the mouse wheel.")
            )

            FeatureModuleCard(model: model, featureID: "touchpadControl", showsHotkeys: false) {
                touchpadGestureSettings
            }

            FeatureModuleCard(model: model, featureID: "mouseOptimize", showsHotkeys: false) {
                mouseOptimizeSettings
            }

            FeatureModuleCard(model: model, featureID: "ddc") {
                DisplayControlPanel()
            }

            FeatureModuleCard(model: model, featureID: "magnifier") {
                magnifierSettings
            }

            FeatureModuleCard(model: model, featureID: "colorpicker") {
                ColorPickerTestRow()
            }
        }
    }

    // MARK: - 分组标题

    private struct SectionHeader: View {
        let title: String
        let subtitle: String?

        init(_ title: String, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }

    // MARK: - 放大镜

    @ViewBuilder
    private var magnifierSettings: some View {
        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("放大倍数", "Zoom level"),
            subtitle: IadenteL10n.t(
                "放大镜浮窗跟随光标，按同一快捷键再次关闭。",
                "The magnifier follows the cursor; press the hotkey again to close."),
            icon: "plus.magnifyingglass",
            colors: IadenteTheme.dashboardColors
        ) {
            Text(String(format: "%.1f×", model.config.magnifierZoom))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }

        Slider(
            value: Binding(
                get: { model.config.magnifierZoom },
                set: {
                    model.config.magnifierZoom = $0
                    model.save()
                }
            ),
            in: 1.5...8,
            step: 0.5
        )

        IadenteNotice(
            text: IadenteL10n.t(
                "放大镜需要「屏幕录制」权限。若浮窗一片空白，请到 系统设置 › 隐私与安全性 › 屏幕录制 勾选 macall 后重启本 App。",
                "The magnifier needs Screen Recording permission. If the window is blank, enable macall under System Settings › Privacy & Security › Screen Recording and relaunch."),
            icon: "info.circle.fill",
            colors: IadenteTheme.dashboardColors
        )
    }

    // MARK: - 触控板手势调节

    @ViewBuilder
    private var touchpadGestureSettings: some View {        IadenteRowDivider()

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
            subtitle:             IadenteL10n.t(
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
            subtitle:             IadenteL10n.t(
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
                "轻量低通滤波，让生硬的滚轮变顺滑（默认不改变滚动总量）。可在下方切换『完整惯性』。",
                "A light low-pass filter that softens the wheel (no change to total scroll by default). Switch to full inertia below."),
            icon: "waveform.path",
            colors: IadenteTheme.dashboardColors,
            isOn: Binding(
                get: { model.config.mouseSmoothScroll },
                set: { model.config.mouseSmoothScroll = $0; model.save() }
            )
        )

        IadenteControlRow(
            IadenteL10n.t("平滑模式", "Smoothing mode"),
            subtitle: IadenteL10n.t(
                "轻量：直接透传滤波后的值，最稳；完整：带惯性滑行尾迹（像触控板那样有减速过程）。",
                "Light: pass the filtered value through (safest). Full: adds inertial glide with a deceleration tail."),
            icon: "slider.horizontal.below.rectangle",
            colors: IadenteTheme.dashboardColors
        ) {
            Picker("", selection: Binding(
                get: { model.config.mouseSmoothMode },
                set: { model.config.mouseSmoothMode = $0; model.save() }
            )) {
                Text(IadenteL10n.t("轻量", "Light")).tag(MouseSmoothMode.light)
                Text(IadenteL10n.t("完整惯性", "Full inertia")).tag(MouseSmoothMode.full)
            }
            .labelsHidden()
            .frame(width: 130)
        }

        IadenteRowDivider()

        IadenteSettingToggle(
            IadenteL10n.t("侧键互换", "Swap side buttons"),
            subtitle: IadenteL10n.t(
                "把鼠标前进 / 后退侧键对调（X1 后退 ↔ X2 前进），适合左撇子或习惯反向的鼠标。",
                "Swap the mouse forward/back side buttons (X1 back ↔ X2 forward), handy for lefties or reversed mice."),
            icon: "arrow.left.arrow.right.circle",
            colors: IadenteTheme.dashboardColors,
            isOn: Binding(
                get: { model.config.mouseSideButtonSwap },
                set: { model.config.mouseSideButtonSwap = $0; model.save() }
            )
        )

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

    private func edgeActionLabel(_ a: TouchpadEdgeAction) -> String {
        switch a {
        case .brightness: return IadenteL10n.t("亮度", "Brightness")
        case .volume: return IadenteL10n.t("音量", "Volume")
        case .off: return IadenteL10n.t("关闭", "Off")
        }
    }
}

// MARK: - 显示器亮度 / 音量实测面板

/// 列出所有在线显示器，直接拖动即可验证 DDC 是否生效（不必先记快捷键）。
private struct DisplayControlPanel: View {
    @State private var displays: [DisplayEntry] = []
    @State private var ddcVolume: Double = 50
    @State private var ddcVolumeSupported: Bool? = nil

    struct DisplayEntry: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltin: Bool
        var brightness: Double
        var readable: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            if displays.isEmpty {
                Text(IadenteL10n.t("未检测到在线显示器", "No online display detected"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach($displays) { $d in
                IadenteControlRow(
                    d.name,
                    subtitle: d.readable
                        ? IadenteL10n.t("亮度可控（DisplayServices）", "Brightness controllable (DisplayServices)")
                        : IadenteL10n.t("该显示器不响应亮度接口", "This display does not respond to the brightness API"),
                    icon: d.isBuiltin ? "laptopcomputer" : "display",
                    colors: IadenteTheme.dashboardColors
                ) {
                    Text("\(Int(d.brightness * 100))%")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { d.brightness },
                        set: { v in
                            d.brightness = v
                            _ = DDC.setBrightness(display: d.id, level: Float(v))
                        }
                    ),
                    in: 0...1
                )
                .disabled(!d.readable)
            }

            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("显示器音量（DDC-CI）", "Monitor volume (DDC-CI)"),
                subtitle: ddcVolumeSupported == false
                    ? IadenteL10n.t(
                        "当前显示器不支持 DDC-CI 音量（笔记本内置屏与多数 USB-C 转接链路都不支持）。",
                        "This display does not support DDC-CI volume.")
                    : IadenteL10n.t(
                        "通过 I2C 直接控制外接显示器的内置扬声器音量。",
                        "Controls the built-in speakers of an external monitor over I2C."),
                icon: "speaker.wave.2",
                colors: IadenteTheme.dashboardColors
            ) {
                Text("\(Int(ddcVolume))")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { ddcVolume },
                    set: { v in
                        ddcVolume = v
                        ddcVolumeSupported = DDC.sendVCP(.volume, value: UInt16(v))
                    }
                ),
                in: 0...100,
                step: 1
            )

            HStack {
                Spacer()
                Button(IadenteL10n.t("重新检测", "Re-detect")) { reload() }
                    .controlSize(.small)
                    .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.dashboardColors))
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        displays = ids.prefix(Int(count)).map { id in
            let level = DDC.getBrightness(display: id)
            return DisplayEntry(
                id: id,
                name: Self.displayName(id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                brightness: Double(level ?? 0.5),
                readable: level != nil)
        }

        if let v = DDC.readVCP(.volume) {
            ddcVolume = Double(v)
            ddcVolumeSupported = true
        } else {
            ddcVolumeSupported = false
        }
    }

    private static func displayName(_ id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               num == id {
                return screen.localizedName
            }
        }
        return "Display \(id)"
    }
}

// MARK: - 取色测试

private struct ColorPickerTestRow: View {
    @State private var hex: String = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IadenteRowDivider()

            IadenteControlRow(
                IadenteL10n.t("立即取色", "Pick now"),
                subtitle: IadenteL10n.t(
                    "点一下就能验证功能，结果同时写入剪贴板。上次结果：\(hex)",
                    "Verify without the hotkey; the result is copied. Last: \(hex)"),
                icon: "eyedropper.halffull",
                colors: IadenteTheme.dashboardColors
            ) {
                Button(IadenteL10n.t("取色", "Pick")) { pick() }
                    .controlSize(.small)
                    .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.dashboardColors))
            }
        }
    }

    private func pick() {
        let sampler = NSColorSampler()
        sampler.show { color in
            guard let color, let rgb = color.usingColorSpace(.sRGB) else { return }
            let s = String(
                format: "#%02X%02X%02X",
                Int((rgb.redComponent * 255).rounded()),
                Int((rgb.greenComponent * 255).rounded()),
                Int((rgb.blueComponent * 255).rounded()))
            hex = s
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
}
