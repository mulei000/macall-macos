import AppKit
import CoreGraphics
import SwiftUI

/// 屏幕设置页：显示器控制（DDC）、屏幕放大镜、屏幕取色。
/// 触控板与鼠标已独立成一级 tab（TrackpadMouseSettingsView），不再放在这里。
struct DisplaySettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        IadenteSettingsPage {
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
