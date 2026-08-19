import CoreAudio
import Foundation

// MARK: - CoreAudio 辅助（逐 App 音频所需）

/// 封装逐 App 音频所需的底层 CoreAudio 查询与对象创建。
/// 移植自 FineTune（GPL v3）的 AudioObjectID 扩展，按需精简并适配 macall 单模块风格。
enum CoreAudioHelpers {

    // MARK: - 进程列表

    /// 枚举当前正在产生/拥有音频对象的进程（AudioObjectID 列表）。
    /// 需要用 `processPID` / `processBundleID` 进一步解析成具体 App。
    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: .unknown, count: max(count, 0))
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
        return objectIDs
    }

    // MARK: - 单进程属性

    static func processIsRunning(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    static func processPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func processBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
        var cfString: CFString = "" as CFString
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfString) == noErr else { return nil }
        return cfString as String
    }

    // MARK: - 设备属性

    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
        var cfString: CFString = "" as CFString
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfString) == noErr else { return nil }
        return cfString as String
    }

    static func deviceName(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
        var cfString: CFString = "" as CFString
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfString) == noErr else { return nil }
        return cfString as String
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: AudioDeviceID = .unknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        return value
    }

    static func defaultOutputDeviceUID() -> String? {
        deviceUID(defaultOutputDevice())
    }

    // MARK: - 输入设备（供音量弹窗头部显示输入设备状态，FineTune 风格）

    static func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: AudioDeviceID = .unknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        return value
    }

    static func defaultInputDeviceUID() -> String? {
        deviceUID(defaultInputDevice())
    }

    /// 默认输入设备（麦克风）的显示名，用于弹窗头部状态条。失败返回 nil。
    static func defaultInputDeviceName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(defaultInputDevice(), &address, 0, nil, &size) == noErr else { return nil }
        var cfString: CFString = "" as CFString
        guard AudioObjectGetPropertyData(defaultInputDevice(), &address, 0, nil, &size, &cfString) == noErr else { return nil }
        return cfString as String
    }

    static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - 设备就绪

    static func isDeviceAlive(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive) == noErr && isAlive != 0
    }

    /// 轮询等待聚合设备就绪（处理 HAL 事件），避免创建后立刻使用导致失败。
    static func waitUntilReady(_ deviceID: AudioObjectID, timeout: TimeInterval = 2.0, pollInterval: TimeInterval = 0.01) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            if isDeviceAlive(deviceID) { return true }
            CFRunLoopRunInMode(.defaultMode, pollInterval, false)
        }
        return false
    }

    // MARK: - 聚合 / 多输出设备创建

    /// 创建聚合设备（含真实输出子设备 + 可选 tap 子设备列表）。返回 AudioObjectID，失败返回 nil。
    static func createAggregateDevice(_ description: CFDictionary) -> AudioObjectID? {
        var deviceID: AudioObjectID = .unknown
        let err = AudioHardwareCreateAggregateDevice(description, &deviceID)
        guard err == noErr else {
            Log.error("[perapp] 创建聚合设备失败: \(err)")
            return nil
        }
        return deviceID
    }

    static func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        guard deviceID.isValid else { return }
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    /// 按显示名查找并销毁遗留的聚合设备（用于清理旧版本功能创建的聚合设备）。
    static func destroyAggregateDevice(named name: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return }
        var ids = [AudioDeviceID](repeating: .unknown, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return }
        for id in ids where id.isValid {
            guard deviceName(id) == name else { continue }
            destroyAggregateDevice(id)
            Log.info("[coreaudio] 已清理遗留聚合设备: \(name)")
        }
    }
}

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var isValid: Bool { self != Self.unknown }
}
