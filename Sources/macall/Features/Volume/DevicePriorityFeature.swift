import CoreAudio
import Foundation

// MARK: - 设备优先级（自动路由）

/// 监听系统音频设备列表变化：当开启「自动路由」且用户未显式指定输出设备时，
/// 自动把当前在线、且在优先级列表中排序最靠前的输出设备设为系统默认输出。
/// 插入更优先的设备（如外接音箱）时自动切换过去；拔掉则回退到次优先设备。
final class DevicePriorityFeature: Feature {
    let id = "devicepriority"
    let title = IadenteL10n.t("设备优先级", "Device Priority")
    let category = FeatureCategory.system
    var enabledByDefault: Bool = true

    private var context: AppContext?
    private var listenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var installed = false

    func install(context: AppContext) {
        self.context = context
        guard !installed else { reconcile(); return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioDevicesChanged, object: nil)
                self?.reconcile()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listenerAddress, DispatchQueue.main, block)
        installed = true
        reconcile()
    }

    func reload(config: Configuration) {
        context?.config = config
        reconcile()
    }

    func uninstall() {
        if installed, let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listenerAddress, DispatchQueue.main, block)
        }
        listenerBlock = nil
        installed = false
    }

    /// 根据配置把最高优先级在线输出设备设为系统默认（仅在自动路由开启且未显式指定设备时）。
    private func reconcile() {
        guard let cfg = context?.config else { return }
        guard cfg.autoRouteOutput, cfg.outputDeviceUIDs.isEmpty else { return }
        let devices = VolumeCore.outputDevices()
        guard !devices.isEmpty else { return }

        let priority = cfg.devicePriority
        let ordered = devices.sorted {
            let i0 = priority.firstIndex(of: $0.uid) ?? Int.max
            let i1 = priority.firstIndex(of: $1.uid) ?? Int.max
            return i0 < i1
        }
        guard let top = ordered.first, !top.isDefault else { return }
        VolumeCore.setDefaultOutputDevice(top.id)
        Log.info("[devicepriority] 自动路由到：\(top.displayName)")
    }
}
