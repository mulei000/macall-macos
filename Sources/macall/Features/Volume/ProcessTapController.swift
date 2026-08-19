import AudioToolbox
import CoreAudio
import Foundation
import os

// MARK: - 逐 App 音频拦截器

/// 为一个正在发声的 App 创建 CoreAudio **进程 tap**（拦截其音频），
/// 并构建一个包含该 tap + 真实输出设备的**逐 App 聚合设备**，
/// 在 IO proc 里按比例增益（0…1）改写采样，实现逐 App 音量 / 静音 / 路由。
///
/// 设计要点（移植自 FineTune GPL v3，按 macall 风格精简：去掉 EQ / 音量增强 / 交叉淡化）：
/// - `muteBehavior = .mutedWhenTapped`：App 原始直接输出被静音，音频只走我们的 tap → 聚合 → 输出。
/// - IO proc 运行在 CoreAudio 实时线程，回调里**禁止**分配内存 / 加锁 / 日志 / Obj-C 消息。
/// - 增益（volume）与静音（muted）用 `nonisolated(unsafe)` 单字对齐变量，主线程写、实时线程读，原子安全。
final class ProcessTapController {
    // MARK: - 常量

    /// 逐 App 音量上限（支持 >100% 增益，配合软限幅避免爆音）。
    static let maxVolume: Float = 2.0

    let app: AudioApp
    private let logger: Logger
    private let queue = DispatchQueue(label: "macall.ProcessTapController", qos: .userInitiated)

    // MARK: - RT 安全状态（主线程写，实时线程读）

    private nonisolated(unsafe) var _volume: Float = 1.0
    private nonisolated(unsafe) var _primaryCurrentVolume: Float = 1.0
    private nonisolated(unsafe) var _isMuted: Bool = false

    // MARK: - 非 RT 状态

    /// 音量斜坡系数（按聚合设备采样率计算，约 30ms 过渡，避免爆音）。
    private var rampCoefficient: Float = 0.0007
    private var targetDeviceUIDs: [String]
    private(set) var currentDeviceUIDs: [String] = []

    // MARK: - CoreAudio 状态

    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapUUID: UUID?
    private var activated = false

    // MARK: - 公开属性

    var volume: Float {
        get { _volume }
        set { _volume = max(0, min(ProcessTapController.maxVolume, newValue)) }
    }

    var isMuted: Bool {
        get { _isMuted }
        set { _isMuted = newValue }
    }

    // MARK: - 初始化

    init(app: AudioApp, targetDeviceUIDs: [String]) {
        precondition(!targetDeviceUIDs.isEmpty, "至少需要一个目标输出设备")
        self.app = app
        self.targetDeviceUIDs = targetDeviceUIDs
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "macall", category: "ProcessTapController(\(app.name))")
    }

    // MARK: - 聚合设备描述

    /// 构建逐 App 聚合设备描述：真实输出设备作为子设备，tap 作为子 tap。
    /// 首个输出设备为时钟源（无需漂移补偿），其余启用漂移补偿以同步。
    private func buildAggregateDescription(outputUIDs: [String], tapUUID: UUID, name: String) -> [String: Any] {
        var subDevices: [[String: Any]] = []
        for (index, deviceUID) in outputUIDs.enumerated() {
            subDevices.append([
                kAudioSubDeviceUIDKey: deviceUID,
                kAudioSubDeviceDriftCompensationKey: index > 0,
            ])
        }
        let clockUID = outputUIDs[0]
        return [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceClockDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ],
            ],
        ]
    }

    // MARK: - 激活 / 失效

    func activate() throws {
        guard !activated else { return }
        logger.debug("激活 tap: \(self.app.name)")

        // 1) 创建进程 tap（拦截该 App 音频）。用 processObjectIDs（宿主 + helper/XPC 进程），
        // 保证如 Safari WebKit 进程、Chrome helper 这类实际发声的子进程也被纳入拦截范围。
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: app.processObjectIDs)
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped
        self.tapUUID = tapDesc.uuid

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "创建进程 tap 失败（可能需要「屏幕录制」权限）: \(err)"])
        }
        processTapID = tapID

        // 2) 构建并创建逐 App 聚合设备
        let description = buildAggregateDescription(
            outputUIDs: targetDeviceUIDs,
            tapUUID: tapDesc.uuid,
            name: "macall-app-\(app.persistenceKey)"
        )
        guard let aggID = CoreAudioHelpers.createAggregateDevice(description as CFDictionary) else {
            teardown()
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "创建聚合设备失败"])
        }
        aggregateDeviceID = aggID
        guard CoreAudioHelpers.waitUntilReady(aggID, timeout: 2.0) else {
            teardown()
            throw NSError(domain: "ProcessTapController", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "聚合设备在超时内未就绪"])
        }

        // 3) 按真实采样率计算音量斜坡系数（约 30ms，避免爆音）
        let sampleRate = CoreAudioHelpers.nominalSampleRate(aggID) ?? 48000
        rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * 0.030))

        // 4) 创建 IO proc：读取 tap 音频 → 按比例增益 → 写入输出
        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggID, queue) { [weak self] _, inInput, _, outOutput, _ in
            self?.processAudio(inInput, to: outOutput)
        }
        guard err == noErr else {
            teardown()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "创建 IO proc 失败: \(err)"])
        }
        err = AudioDeviceStart(aggID, deviceProcID)
        guard err == noErr else {
            teardown()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "启动设备失败: \(err)"])
        }

        _primaryCurrentVolume = _volume
        currentDeviceUIDs = targetDeviceUIDs
        activated = true
        logger.info("tap 已激活: \(self.app.name)，目标设备 \(self.targetDeviceUIDs.count) 个")
    }

    /// 同步重建（用于设备路由变更）：销毁旧 tap/聚合，按新设备重新激活。
    func updateDevices(to newUIDs: [String]) throws {
        guard activated else { targetDeviceUIDs = newUIDs; return }
        guard newUIDs != targetDeviceUIDs, !newUIDs.isEmpty else { return }
        let savedVolume = _volume
        let savedMuted = _isMuted
        teardown()
        targetDeviceUIDs = newUIDs
        try activate()
        _volume = savedVolume
        _isMuted = savedMuted
    }

    func invalidate() {
        guard activated else { return }
        activated = false
        teardown()
        logger.info("tap 已失效: \(self.app.name)")
    }

    /// 同步拆除所有 CoreAudio 资源（主线程调用即可）。
    private func teardown() {
        if let proc = deviceProcID {
            AudioDeviceStop(aggregateDeviceID, proc)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
            deviceProcID = nil
        }
        CoreAudioHelpers.destroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = .unknown
        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
        }
        tapUUID = nil
    }

    deinit { teardown() }

    // MARK: - 实时音频回调（禁止分配 / 加锁 / 日志 / Obj-C 消息）

    private func processAudio(_ inputBufferList: UnsafePointer<AudioBufferList>,
                              to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        if _isMuted {
            for ob in outputBuffers {
                guard let data = ob.mData else { continue }
                memset(data, 0, Int(ob.mDataByteSize))
            }
            return
        }

        let target = _volume
        var current = _primaryCurrentVolume
        let inputCount = inputBuffers.count
        let outputCount = outputBuffers.count

        for oi in 0..<outputCount {
            let ob = outputBuffers[oi]
            guard let odata = ob.mData else { continue }

            // 某些 USB 接口会多出麦克风输入缓冲；把最后 N 个输入映射到 N 个输出。
            let ii = inputCount > outputCount ? (inputCount - outputCount + oi) : oi
            guard ii < inputCount else {
                memset(odata, 0, Int(ob.mDataByteSize))
                continue
            }
            guard let idata = inputBuffers[ii].mData else {
                memset(odata, 0, Int(ob.mDataByteSize))
                continue
            }

            let ins = idata.assumingMemoryBound(to: Float.self)
            let outs = odata.assumingMemoryBound(to: Float.self)
            let n = Int(inputBuffers[ii].mDataByteSize) / MemoryLayout<Float>.size

            for i in 0..<n {
                current += (target - current) * rampCoefficient
                var x = ins[i]
                var s = x * current
                s = ProcessTapController.softLimit(s)
                outs[i] = s
            }
        }
        _primaryCurrentVolume = current
    }

    // MARK: - 实时 DSP 辅助（无分配 / 无捕获）

    /// 平滑软限幅：|x|≤1 原样通过；超过 1 的部分用代数饱和压回（界于 ±2），
    /// 避免增益 >100% 时的硬削波爆音。
    private static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 1.0 { return x }
        let sign: Float = x < 0 ? -1 : 1
        let e = a - 1.0
        return sign * (1.0 + e / (1.0 + e))
    }
}
