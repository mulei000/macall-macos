import AppKit
import CoreAudio
import Foundation

// MARK: - 输出设备切换器（Output Switcher）

/// ⌃⌥K（可自定义）：在「用户勾选的输出设备」之间循环切换系统默认输出。
/// 勾选列表为空时，循环全部可用输出设备。
///
/// 纯复用既有 `VolumeCore`（设备枚举 / 切换系统默认输出）与 `SceneToast`（切换提示），
/// 不新增任何音频引擎或全局监听——只在快捷键命中时做一次 CoreAudio 写操作。
/// 循环位置以「当前系统默认输出」为基准，每次取池中的下一个，天然支持热插拔。
final class OutputSwitcherFeature: Feature {
    let id = "outputswitcher"
    let title = IadenteL10n.t("输出设备切换", "Output Switcher")
    let category = FeatureCategory.system
    var enabledByDefault: Bool = true

    private var context: AppContext?
    /// 缓存最新配置，使 `handle` 能读到设置页最新的循环范围勾选。
    private var config: Configuration?

    func install(context: AppContext) {
        self.context = context
        self.config = context.config
        bindHotkey(using: context.config)
        Log.info("[outputswitcher] 已安装：⌃⌥K 在输出设备间循环切换")
    }

    private func bindHotkey(using config: Configuration) {
        // 安全取快捷键组合：配置缺失回退默认表；默认表也可能缺该 key，可选链 + guard 兜底。
        let combo = config.hotkeys["outputswitcher.cycle"]?.toCombo()
            ?? Configuration.defaultHotkeys()["outputswitcher.cycle"]?.toCombo()
        guard let combo = combo else {
            Log.warning("[outputswitcher] 默认快捷键表缺少 outputswitcher.cycle，跳过绑定")
            return
        }
        context?.hotkeys.bind(
            featureId: id, action: "cycle", configKey: "outputswitcher.cycle", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "cycle" { cycleOutputDevice() }
    }

    func reload(config: Configuration) {
        self.config = config
        bindHotkey(using: config)
    }

    func uninstall() {}

    // MARK: - 循环切换

    private func cycleOutputDevice() {
        guard let config = config else { return }

        let all = VolumeCore.outputDevices()
        guard !all.isEmpty else {
            SceneToast.shared.show(IadenteL10n.t("无可用输出设备", "No output devices"))
            return
        }

        // 勾选范围（空 = 全部）。
        let selected = config.outputSwitcherDeviceUIDs
        let filtered = selected.isEmpty ? all : all.filter { selected.contains($0.uid) }
        // 用户勾选了但当前设备已离线：退化为全部，避免循环池为空。
        let pool = filtered.isEmpty ? all : filtered

        guard pool.count >= 2 else {
            let only = pool.first?.displayName ?? ""
            SceneToast.shared.show(
                IadenteL10n.t("只有一个输出设备：\(only)", "Only one output: \(only)"))
            return
        }

        // 以当前系统默认输出为基准，跳到池中的下一个（不在池内则从末尾开始）。
        let currentUID = all.first(where: { $0.isDefault })?.uid
        let startIndex: Int
        if let idx = pool.firstIndex(where: { $0.uid == currentUID }) {
            startIndex = idx
        } else {
            startIndex = pool.count - 1
        }
        let next = pool[(startIndex + 1) % pool.count]
        VolumeCore.setDefaultOutputDevice(next.id)
        Log.info("[outputswitcher] 切换到输出设备：\(next.displayName)")
        SceneToast.shared.show(
            IadenteL10n.t("输出：\(next.displayName)", "Output: \(next.displayName)"))
    }
}
