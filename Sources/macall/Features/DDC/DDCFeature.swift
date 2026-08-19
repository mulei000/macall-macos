import CoreGraphics
import Foundation

// MARK: - DDC 显示器控制

/// 外接显示器控制：亮度（⌃⌥, / ⌃⌥.）与音量（⌃⌥/ / ⌃⌥'）。
/// 亮度走 DisplayServices（Apple Silicon 上真实可用）；音量走 DDC-CI over I2C（best-effort，需真实外接显示器）。
final class DDCFeature: Feature {
    let id = "ddc"
    let title = IadenteL10n.t("显示器控制 (DDC)", "Display Control (DDC)")
    let category = FeatureCategory.system
    var enabledByDefault: Bool = true

    private var context: AppContext?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[ddc] 已安装：⌃⌥,/⌃⌥. 调亮度，⌃⌥//⌃⌥' 调音量")
    }

    private func bindHotkey(using config: Configuration) {
        for (action, key) in [("brightnessDown", "ddc.brightnessDown"),
                               ("brightnessUp", "ddc.brightnessUp"),
                               ("volumeDown", "ddc.volumeDown"),
                               ("volumeUp", "ddc.volumeUp")] {
            let combo = config.hotkeys[key]?.toCombo() ?? Configuration.defaultHotkeys()[key]!.toCombo()
            context?.hotkeys.bind(featureId: id, action: action, configKey: key, defaultCombo: combo)
        }
    }

    func handle(action: String) {
        switch action {
        case "brightnessDown": adjustBrightness(-0.1)
        case "brightnessUp": adjustBrightness(0.1)
        case "volumeDown": adjustVolume(-5)
        case "volumeUp": adjustVolume(5)
        default: break
        }
    }

    func reload(config: Configuration) { bindHotkey(using: config) }
    func uninstall() {}

    // MARK: - 亮度（DisplayServices）

    private func adjustBrightness(_ delta: Float) {
        let displays = onlineDisplays()
        guard !displays.isEmpty else { return }
        // 以第一个能读到亮度的显示器为基准。
        var base: Float = 0.5
        for d in displays { if let b = DDC.getBrightness(display: d) { base = b; break } }
        let newLevel = max(0, min(1, base + delta))
        for d in displays { _ = DDC.setBrightness(display: d, level: newLevel) }
        Log.info("[ddc] 亮度 → \(Int(newLevel * 100))%")
    }

    // MARK: - 音量（DDC-CI）

    private func adjustVolume(_ delta: Int) {
        let displays = onlineDisplays()
        var current = 50
        for d in displays { if let v = DDC.readVCP(.volume) { current = Int(v); break } }
        let newVol = max(0, min(100, current + delta))
        let scaled = UInt16(newVol) // DDC 音量通常 0…100
        for d in displays { _ = DDC.sendVCP(.volume, value: scaled) }
        Log.info("[ddc] 音量 → \(newVol)%")
    }

    // MARK: - 显示器枚举

    private func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids[0..<Int(count)])
    }
}
