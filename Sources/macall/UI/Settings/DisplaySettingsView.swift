import AppKit
import CoreGraphics
import SwiftUI

/// 屏幕设置页：显示器控制（DDC）、屏幕放大镜、屏幕取色。
/// 每个模块的总开关都在自己卡片右上角，样式与其他页面完全一致。
struct DisplaySettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        IadenteSettingsPage {
            FeatureModuleCard(model: model, featureID: "touchpadControl", showsHotkeys: false) {
                touchpadGestureSettings
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
            Slider(
                value: Binding(
                    get: { model.config.touchpadSensitivity },
                    set: { model.config.touchpadSensitivity = $0; model.save() }
                ),
                in: 0.2...1.5, step: 0.05
            )
            .frame(width: 170)
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
