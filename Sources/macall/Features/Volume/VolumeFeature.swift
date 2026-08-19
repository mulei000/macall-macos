import AppKit
import CoreAudio
import Foundation

// MARK: - 音量控制（CoreAudio）

/// 读取/设置默认输出设备的主音量与静音。CoreAudio 跨版本稳定。
/// 净新增模块，不依赖任何参考项目。
final class VolumeFeature: Feature {
    let id = "volume"
    let title = IadenteL10n.t("音量控制", "Volume Control")
    let category = FeatureCategory.system
    var enabledByDefault: Bool = true

    private var context: AppContext?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        // 清理旧版本输入监听功能遗留的聚合设备（该功能已移除）。
        MACatchException {
            CoreAudioHelpers.destroyAggregateDevice(named: "macall-inputmonitor")
        }
        // 复现持久化的多设备输出设置。CoreAudio 聚合设备创建偶发 ObjC 异常，
        // 单独隔离：即便失败也不影响后续逐 App 音频引擎启动与音量控制。
        MACatchException {
            self.applyOutputDevices(context.config)
        }
        PerAppAudioEngine.shared.start()
        PerAppAudioEngine.shared.applyControlledMap(controlledMap(from: context.config))
        lastOutputWasHeadphones = VolumeCore.outputDeviceLooksLikeHeadphones(VolumeCore.defaultOutputDevice())
        if context.config.autoDuckOnHeadphoneUnplug {
            installDuckListener()
        }
        Log.info("[volume] 已安装：⌃⌥X 切换静音；逐 App 音频引擎已启动")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["volume.mute"]?.toCombo()
            ?? Configuration.defaultHotkeys()["volume.mute"]!.toCombo()
        context?.hotkeys.bind(
            featureId: id, action: "mute", configKey: "volume.mute", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "mute" { VolumeCore.toggleMute() }
    }

    func reload(config: Configuration) {
        bindHotkey(using: config)
        applyOutputDevices(config)
        PerAppAudioEngine.shared.applyControlledMap(controlledMap(from: config))
        lastOutputWasHeadphones = VolumeCore.outputDeviceLooksLikeHeadphones(VolumeCore.defaultOutputDevice())
        if config.autoDuckOnHeadphoneUnplug {
            installDuckListener()
        } else {
            removeDuckListener()
        }
    }
    func uninstall() {
        removeDuckListener()
        PerAppAudioEngine.shared.stop()
    }

    /// 由 Configuration 计算「受控 App → 音量/静音/路由」映射，下发给逐 App 音频引擎。
    private func controlledMap(from config: Configuration) -> [String: PerAppState] {
        var map: [String: PerAppState] = [:]
        for (key, vol) in config.perAppVolume {
            map[key] = PerAppState(
                volume: vol,
                muted: config.perAppMuted[key] ?? false,
                devices: config.perAppDeviceUIDs[key] ?? []
            )
        }
        return map
    }

    /// 根据用户选择的输出设备（Configuration.outputDeviceUIDs）应用系统输出：
    /// 单个 UID → 设为默认输出设备；空数组（或旧版残留的多 UID）→ 不干预，跟随系统默认。
    /// 多设备输出（聚合组合设备）功能已废弃，不再创建/切换组合设备。
    private func applyOutputDevices(_ config: Configuration) {
        let uids = config.outputDeviceUIDs
        guard uids.count == 1 else { return } // 空或 >1 一律视为「跟随系统」
        if let dev = VolumeCore.deviceWithUID(uids[0]) {
            VolumeCore.setDefaultOutputDevice(dev)
        }
    }

    // MARK: - 耳机拔出自动降音量

    /// 监听系统默认输出设备变化：从「耳机类」切到「非耳机类」时把主音量降到用户设定值，
    /// 避免外放突然以高音量炸响（例如 AirPods 断连、USB 耳麦拔出）。
    /// 由 Configuration.autoDuckOnHeadphoneUnplug 控制是否启用，autoDuckTargetVolume 控制目标音量。
    private var duckListenerBlock: AudioObjectPropertyListenerBlock?
    private var lastOutputWasHeadphones: Bool = false

    private func installDuckListener() {
        guard duckListenerBlock == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChanged()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        duckListenerBlock = block
        Log.info("[volume] 已安装耳机拔出降音量监听")
    }

    private func removeDuckListener() {
        guard let block = duckListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        duckListenerBlock = nil
    }

    private func handleDefaultOutputChanged() {
        let newID = VolumeCore.defaultOutputDevice()
        let wasHeadphones = lastOutputWasHeadphones
        let isHeadphones = VolumeCore.outputDeviceLooksLikeHeadphones(newID)
        lastOutputWasHeadphones = isHeadphones
        guard wasHeadphones, !isHeadphones else { return }
        // 仅在确有主音量通道时降，避免对 HDMI 等无音量设备做无意义写入。
        guard VolumeCore.getVolume() != nil else { return }
        let target = Float(context?.config.autoDuckTargetVolume ?? 0.25)
        let targetPct = Int(round(target * 100))
        VolumeCore.setVolume(target)
        Log.info("[volume] 检测到从耳机切到非耳机，主音量降到 \(targetPct)%")
        SceneToast.shared.show(
            IadenteL10n.t("已拔出耳机，主音量降到 \(targetPct)%",
                          "Headphones unplugged — volume lowered to \(targetPct)%"))
    }

    // MARK: - 对外读写（供设置页滑块使用）

    static var currentVolume: Float {
        get { VolumeCore.getVolume() ?? 1.0 }
        set { VolumeCore.setVolume(newValue) }
    }

    static var isMuted: Bool { VolumeCore.getMute() ?? false }
}

// MARK: - CoreAudio 封装

enum VolumeCore {
    static func defaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }

    static func getVolume() -> Float? {
        let device = defaultOutputDevice()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0) // 0 = 主音量
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func setVolume(_ v: Float) {
        let device = defaultOutputDevice()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0)
        guard AudioObjectHasProperty(device, &addr) else { return }
        var value = Float32(min(max(v, 0), 1))
        var size = UInt32(MemoryLayout<Float32>.size)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value)
    }

    static func getMute() -> Bool? {
        let device = defaultOutputDevice()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? (value != 0) : nil
    }

    static func setMute(_ muted: Bool) {
        let device = defaultOutputDevice()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0)
        guard AudioObjectHasProperty(device, &addr) else { return }
        var value = UInt32(muted ? 1 : 0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value)
    }

    static func toggleMute() {
        if let m = getMute() { setMute(!m) }
    }

    // MARK: - 输入设备（麦克风）静音

    static func getInputMute() -> Bool? {
        let device = CoreAudioHelpers.defaultInputDevice()
        guard device != 0 else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? (value != 0) : nil
    }

    @discardableResult
    static func setInputMute(_ muted: Bool) -> Bool {
        let device = CoreAudioHelpers.defaultInputDevice()
        guard device != 0 else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0)
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &addr),
           AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value) == noErr {
            return true
        }
        // 回退：把输入音量拉到 0 / 恢复到 1
        var vaddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0)
        guard AudioObjectHasProperty(device, &vaddr) else { return false }
        var v = Float32(muted ? 0 : 1)
        let vsize = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &vaddr, 0, nil, vsize, &v) == noErr
    }

    /// 输入设备是否可被静音（硬件静音或音量可写）。
    static func inputMuteAvailable() -> Bool {
        let device = CoreAudioHelpers.defaultInputDevice()
        guard device != 0 else { return false }
        var maddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0)
        if AudioObjectHasProperty(device, &maddr) { return true }
        var vaddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0)
        return AudioObjectHasProperty(device, &vaddr)
    }

    // MARK: - 输出设备管理 / 多输出

    /// 排除 macall 自身或其他虚拟路由软件创建的聚合设备，避免它们混进用户可选列表。
    /// 例如：逐 App 音量创建的 `macall-app-com.google.Chrome`、Background Music 的 aggregate。
    private static func isUserFacingOutputDevice(name: String, uid: String) -> Bool {
        let lower = name.lowercased()
        let uidLower = uid.lowercased()
        if lower.hasPrefix("macall-app-") || uidLower.hasPrefix("macall-app-") { return false }
        if lower.contains("background music") || uidLower.contains("background music") { return false }
        return true
    }

    /// 枚举所有可用输出设备（含系统已有的聚合/多输出设备）。
    static func outputDevices() -> [AudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: max(count, 0))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let def = defaultOutputDevice()
        return ids.compactMap { id in
            guard hasOutput(id) else { return nil }
            let name = deviceName(id) ?? "设备 \(id)"
            let uid = deviceUID(id) ?? ""
            guard isUserFacingOutputDevice(name: name, uid: uid) else { return nil }
            return AudioDeviceInfo(
                id: id,
                name: name,
                uid: uid,
                isDefault: id == def,
                isAggregate: transportType(id) == kAudioDeviceTransportTypeAggregate)
        }
    }

    /// 按 UID 查找设备（用于把持久化的 UID 还原成 AudioDeviceID）。
    static func deviceWithUID(_ uid: String) -> AudioDeviceID? {
        outputDevices().first { $0.uid == uid }?.id
    }

    /// 设置系统默认输出设备。
    static func setDefaultOutputDevice(_ id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = id
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
    }

    // MARK: - 内部查询

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr && sz > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var sz = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &name) == noErr else { return nil }
        return name as String?
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil
        var sz = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &uid) == noErr else { return nil }
        return uid as String?
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &t) == noErr else { return 0 }
        return t
    }

    // MARK: - 输入设备（麦克风）枚举 / 切换

    /// 枚举所有可作默认输入的设备：有输入流、在线、未隐藏、可作为默认输入。
    static func inputDevices() -> [AudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: max(count, 0))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let def = CoreAudioHelpers.defaultInputDevice()
        return ids.compactMap { id in
            guard hasInput(id) else { return nil }
            guard CoreAudioHelpers.isDeviceAlive(id) else { return nil }
            guard !deviceIsHidden(id) else { return nil }
            guard canBeDefaultDevice(id, scope: kAudioDevicePropertyScopeInput) else { return nil }
            let name = deviceName(id) ?? "设备 \(id)"
            return AudioDeviceInfo(
                id: id,
                name: name,
                uid: deviceUID(id) ?? "",
                isDefault: id == def,
                isAggregate: transportType(id) == kAudioDeviceTransportTypeAggregate)
        }
    }

    /// 按 UID 查找输入设备（麦克风）。
    static func inputDeviceWithUID(_ uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    /// 设置系统默认输入设备（麦克风）。
    static func setDefaultInputDevice(_ id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = id
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
    }

    // MARK: - 系统提示音输出设备

    /// 可设为「系统提示音」输出的设备（即能当默认系统输出设备）。
    static func systemSoundOutputDevices() -> [AudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: max(count, 0))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let def = defaultSystemSoundOutputDevice()
        return ids.compactMap { id in
            guard canBeDefaultSystemDevice(id) else { return nil }
            guard hasOutput(id) else { return nil }
            let name = deviceName(id) ?? "设备 \(id)"
            let uid = deviceUID(id) ?? ""
            guard isUserFacingOutputDevice(name: name, uid: uid) else { return nil }
            return AudioDeviceInfo(
                id: id,
                name: name,
                uid: uid,
                isDefault: id == def,
                isAggregate: transportType(id) == kAudioDeviceTransportTypeAggregate)
        }
    }

    /// 设备是否可被设为系统提示音（默认系统输出）设备。
    static func canBeDefaultSystemDevice(_ id: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr else { return false }
        return v != 0
    }

    /// 当前系统提示音输出设备。
    static func defaultSystemSoundOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }

    /// 设置系统提示音输出设备。
    static func setSystemSoundOutputDevice(_ id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = id
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
    }

    /// 按 UID 查找系统提示音输出设备。
    static func systemSoundDeviceWithUID(_ uid: String) -> AudioDeviceID? {
        systemSoundOutputDevices().first { $0.uid == uid }?.id
    }

    // MARK: - 耳机启发式

    /// 粗略判断输出设备是否为「耳机 / 耳塞」类（用于拔出后自动降音量）。
    /// 依据：设备名 / UID 含常见耳机关键词，或传输类型为蓝牙 / USB。
    static func outputDeviceLooksLikeHeadphones(_ id: AudioDeviceID) -> Bool {
        guard id != 0 else { return false }
        let name = deviceName(id) ?? ""
        let uid = deviceUID(id) ?? ""
        let hay = (name + " " + uid).lowercased()
        let keywords = [
            "headphone", "headset", "airpod", "earpod", "earbuds", "earphone",
            "耳机", "耳塞", " buds", "bud ",
        ]
        if keywords.contains(where: { hay.contains($0) }) { return true }
        let t = transportType(id)
        if t == kAudioDeviceTransportTypeBluetooth
            || t == kAudioDeviceTransportTypeBluetoothLE
            || t == kAudioDeviceTransportTypeUSB {
            return true
        }
        return false
    }

    // MARK: - 内部查询（输入设备过滤用）

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr && sz > 0
    }

    private static func deviceIsHidden(_ id: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr else { return false }
        return v != 0
    }

    private static func canBeDefaultDevice(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr else { return false }
        return v != 0
    }
}

/// 输出设备信息（供设置页展示与选择）。
struct AudioDeviceInfo: Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let isDefault: Bool
    let isAggregate: Bool

    var displayName: String {
        name
    }
}
