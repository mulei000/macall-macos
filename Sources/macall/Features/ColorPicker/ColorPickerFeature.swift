import AppKit
import Foundation
import UserNotifications

// MARK: - 屏幕取色器

/// 复用系统自带的取色放大镜（NSColorSampler），权限无忧、跨版本稳定。
/// 净新增模块，不依赖任何参考项目。
final class ColorPickerFeature: Feature {
    let id = "colorpicker"
    let title = IadenteL10n.t("屏幕取色", "Color Picker")
    let category = FeatureCategory.other
    var enabledByDefault: Bool = true

    var isLaunchableTool: Bool { true }
    var launchAction: String? { "pick" }

    private var context: AppContext?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[colorpicker] 已安装：⌃⌥G 唤起系统取色放大镜")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["colorpicker.pick"]?.toCombo()
            ?? Configuration.defaultHotkeys()["colorpicker.pick"]!.toCombo()
        context?.hotkeys.bind(
            featureId: id, action: "pick", configKey: "colorpicker.pick", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "pick" { pick() }
    }

    func reload(config: Configuration) { bindHotkey(using: config) }
    func uninstall() {}

    private func pick() {
        let sampler = NSColorSampler()
        sampler.show { [weak self] color in
            guard let color else { return }
            let hex = Self.hexString(color)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(hex, forType: .string)
            self?.notify(hex)
        }
    }

    private static func hexString(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func notify(_ hex: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = IadenteL10n.t("颜色已复制", "Color copied")
        content.body = hex
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
