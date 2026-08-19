import AppKit
import CoreAudio
import Foundation

// MARK: - 输入设备切换器（Input Switcher）

/// ⌃⌥Y（可自定义）：在全部可用输入设备（麦克风）之间循环切换系统默认输入。
///
/// 纯复用既有 `VolumeCore`（设备枚举 / 切换系统默认输入）与 `SceneToast`（切换提示），
/// 不新增任何音频引擎或全局监听——只在快捷键命中时做一次 CoreAudio 写操作。
/// 循环位置以「当前系统默认输入」为基准，每次取池中的下一个，天然支持热插拔。
final class InputSwitcherFeature: Feature {
    let id = "inputswitcher"
    let title = IadenteL10n.t("输入设备切换", "Input Switcher")
    let category = FeatureCategory.system
    var enabledByDefault: Bool = true

    private var context: AppContext?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[inputswitcher] 已安装：⌃⌥Y 在输入设备间循环切换")
    }

    private func bindHotkey(using config: Configuration) {
        // 安全取快捷键组合：配置缺失回退默认表；默认表也可能缺该 key，可选链 + guard 兜底。
        let combo = config.hotkeys["inputswitcher.cycle"]?.toCombo()
            ?? Configuration.defaultHotkeys()["inputswitcher.cycle"]?.toCombo()
        guard let combo = combo else {
            Log.warning("[inputswitcher] 默认快捷键表缺少 inputswitcher.cycle，跳过绑定")
            return
        }
        context?.hotkeys.bind(
            featureId: id, action: "cycle", configKey: "inputswitcher.cycle", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "cycle" { cycleInputDevice() }
    }

    func reload(config: Configuration) {
        bindHotkey(using: config)
    }

    func uninstall() {}

    // MARK: - 循环切换

    private func cycleInputDevice() {
        let all = VolumeCore.inputDevices()
        guard !all.isEmpty else {
            SceneToast.shared.show(IadenteL10n.t("无可用输入设备", "No input devices"))
            return
        }

        guard all.count >= 2 else {
            let only = all.first?.displayName ?? ""
            SceneToast.shared.show(
                IadenteL10n.t("只有一个输入设备：\(only)", "Only one input: \(only)"))
            return
        }

        // 以当前系统默认输入为基准，跳到池中的下一个（不在池内则从末尾开始）。
        let currentUID = all.first(where: { $0.isDefault })?.uid
        let startIndex: Int
        if let idx = all.firstIndex(where: { $0.uid == currentUID }) {
            startIndex = idx
        } else {
            startIndex = all.count - 1
        }
        let next = all[(startIndex + 1) % all.count]
        VolumeCore.setDefaultInputDevice(next.id)
        Log.info("[inputswitcher] 切换到输入设备：\(next.displayName)")
        SceneToast.shared.show(
            IadenteL10n.t("输入：\(next.displayName)", "Input: \(next.displayName)"))
    }
}
