import CoreAudio
import Foundation

// MARK: - 系统主音量 / 静音的实时镜像

/// 设置页原先只在 `init` 里读一次 `VolumeCore.getVolume()`，于是：
/// 用控制中心、键盘音量键、耳机线控改音量后，macall 里的滑杆纹丝不动，
/// 下一次拖动又会把系统音量拽回旧值——用户感知就是「不同步」。
///
/// 这里注册 CoreAudio 属性监听，把系统状态实时镜像到 `@Published`，
/// 做到双向同步：外部改 → 滑杆动；滑杆改 → 系统跟。
///
/// 监听三处：
/// 1. 默认输出设备本身变了（换耳机 / 切扬声器）→ 需要重挂监听；
/// 2. 当前设备的 `kAudioDevicePropertyVolumeScalar`；
/// 3. 当前设备的 `kAudioDevicePropertyMute`。
final class SystemVolumeObserver: ObservableObject {
    static let shared = SystemVolumeObserver()

    /// 0…1。写入时会真正设置系统音量。
    @Published var volume: Double = 0 {
        didSet {
            guard !suppressWriteBack else { return }
            VolumeCore.setVolume(Float(volume))
        }
    }

    @Published var muted: Bool = false {
        didSet {
            guard !suppressWriteBack else { return }
            VolumeCore.setMute(muted)
        }
    }

    /// 当前默认输出设备是否暴露主音量通道（部分聚合 / HDMI 设备没有）。
    @Published private(set) var volumeControllable: Bool = true
    @Published private(set) var deviceName: String = "—"

    /// 从系统回填时抑制 `didSet` 的写回，避免「读→写→再触发监听」的回环。
    private var suppressWriteBack = false

    private var observedDevice: AudioDeviceID = 0
    private var deviceListenerInstalled = false

    // 监听地址必须是 var：AudioObjectAddPropertyListenerBlock 的 address 参数是 inout。
    private var defaultDeviceAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var volumeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: 0)
    private var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: 0)

    private lazy var listenerQueue = DispatchQueue(label: "com.macall.volume.observer")

    private init() {
        refreshFromSystem()
        installDefaultDeviceListener()
        attachToCurrentDevice()
    }

    // MARK: - 从系统回填

    /// 读取系统当前值写回 `@Published`，但不触发反向写系统。
    func refreshFromSystem() {
        let v = VolumeCore.getVolume()
        let m = VolumeCore.getMute() ?? false
        let name = Self.currentDeviceName()

        let apply = {
            self.suppressWriteBack = true
            self.volumeControllable = (v != nil)
            self.volume = Double(v ?? 0)
            self.muted = m
            self.deviceName = name
            self.suppressWriteBack = false
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: - 监听安装

    private func installDefaultDeviceListener() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddr, listenerQueue
        ) { [weak self] _, _ in
            guard let self else { return }
            self.detachFromCurrentDevice()
            self.attachToCurrentDevice()
            self.refreshFromSystem()
        }
    }

    private func attachToCurrentDevice() {
        let dev = VolumeCore.defaultOutputDevice()
        guard dev != 0 else { return }
        observedDevice = dev

        let handler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshFromSystem()
        }
        AudioObjectAddPropertyListenerBlock(dev, &volumeAddr, listenerQueue, handler)
        AudioObjectAddPropertyListenerBlock(dev, &muteAddr, listenerQueue, handler)
        deviceListenerInstalled = true
    }

    private func detachFromCurrentDevice() {
        guard deviceListenerInstalled, observedDevice != 0 else { return }
        // Block 版的 Remove 需要传入同一个 block 才能精确摘除；这里设备已切走，
        // 旧设备上的监听随对象消失即可，不做强制摘除以免误删他处监听。
        deviceListenerInstalled = false
        observedDevice = 0
    }

    private static func currentDeviceName() -> String {
        let dev = VolumeCore.defaultOutputDevice()
        guard dev != 0, let uid = CoreAudioHelpers.deviceUID(dev) else { return "—" }
        return VolumeCore.outputDevices().first { $0.uid == uid }?.displayName ?? uid
    }
}
