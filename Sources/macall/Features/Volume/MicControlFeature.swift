import AppKit
import CoreAudio
import Foundation

// MARK: - 麦克风静音（Mic Control）

/// ⌃⌥J（可自定义）：一键切换默认输入设备（麦克风）的静音。
/// 纯复用既有 `VolumeCore`（输入设备静音 / 默认输入设备切换），不新增音频引擎。
/// 设置页可额外指定「默认输入设备」：启动时自动设为系统默认输入，避免每次手动切。
final class MicControlFeature: Feature {
    let id = "miccontrol"
    let title = IadenteL10n.t("麦克风静音", "Mic Mute")
    let category = FeatureCategory.system
    var enabledByDefault: Bool = true

    private var context: AppContext?
    private var config: Configuration?

    func install(context: AppContext) {
        self.context = context
        self.config = context.config
        bindHotkey(using: context.config)
        applyDefaultInputDevice(context.config)
        Log.info("[miccontrol] 已安装：⌃⌥J 切换麦克风静音")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["miccontrol.mute"]?.toCombo()
            ?? Configuration.defaultHotkeys()["miccontrol.mute"]?.toCombo()
        guard let combo = combo else {
            Log.warning("[miccontrol] 默认快捷键表缺少 miccontrol.mute，跳过绑定")
            return
        }
        context?.hotkeys.bind(
            featureId: id, action: "mute", configKey: "miccontrol.mute", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "mute" { toggleMute() }
    }

    private func toggleMute() {
        guard VolumeCore.inputMuteAvailable() else {
            SceneToast.shared.show(IadenteL10n.t("麦克风不可静音", "Mic can't be muted"))
            return
        }
        let nowMuted = !(VolumeCore.getInputMute() ?? false)
        _ = VolumeCore.setInputMute(nowMuted)
        // 通知音量弹窗刷新麦克风图标/开关状态。
        NotificationCenter.default.post(name: NSNotification.Name("macall.volumeInputMuteChanged"), object: nil)
        Log.info("[miccontrol] 麦克风静音=\(nowMuted)")
        SceneToast.shared.show(
            IadenteL10n.t(nowMuted ? "麦克风已静音" : "麦克风已开启",
                          nowMuted ? "Mic muted" : "Mic on"))
    }

    /// 若用户在设置页指定了默认输入设备，启动时把它设为系统默认输入。
    private func applyDefaultInputDevice(_ config: Configuration) {
        let uid = config.defaultInputDeviceUID
        guard !uid.isEmpty, let dev = VolumeCore.inputDeviceWithUID(uid) else { return }
        VolumeCore.setDefaultInputDevice(dev)
    }

    func reload(config: Configuration) {
        self.config = config
        bindHotkey(using: config)
        applyDefaultInputDevice(config)
    }

    func uninstall() {}
}
