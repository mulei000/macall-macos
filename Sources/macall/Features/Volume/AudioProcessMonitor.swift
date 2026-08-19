import AppKit
import CoreAudio
import Darwin
import Foundation

// 轻量指纹：仅比较 pid + objectIDs，避免图标/名称变化触发无谓的列表刷新（移植自 FineTune）。
private struct AppFingerprint: Hashable {
    let pid: pid_t
    let objectIDs: [AudioObjectID]
}

// MARK: - 音频进程监视器

/// 通过 `kAudioHardwarePropertyProcessObjectList` 枚举当前正在产生音频的进程，
/// 解析成具体 `.app`（处理 XPC/helper 进程落到其宿主 App），过滤系统守护进程，
/// 对外发布 `activeApps`。移植自 FineTune（GPL v3），按 macall 风格精简。
final class AudioProcessMonitor {

    private(set) var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?

    /// 用户已在配置中手动开启（受控）的 App 的 bundleID 集合。这些 App 即便未被媒体分类命中，
    /// 也始终出现在自动列表里，避免「分类漏判」把用户明确要控制的 App 藏起来。
    var alwaysIncludeBundleIDs: Set<String> = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var refreshGeneration = 0
    private var periodicRefreshTask: Task<Void, Never>?
    /// 逐进程 `kAudioProcessPropertyIsRunning` 监听：进程开始/停止出声时立即触发刷新，
    /// 比只依赖全局进程列表变化更及时（移植自 FineTune，解决「app 开始/停止播放要等几秒才更新」）。
    private var processListenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var monitoredProcesses: Set<AudioObjectID> = []
    /// 保护 `monitoredProcesses` / `processListenerBlocks` / `refreshGeneration` 的并发访问。
    /// 这几个集合会在后台 `refresh()`、CoreAudio 监听回调、定时器等多线程路径下被同时读写，
    /// 无锁会导致堆损坏并触发 SIGSEGV（访问 0x8000000000000028）。
    private let processStateLock = NSLock()
    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// 系统守护进程的 bundleID 前缀（Siri / coreaudiod / 通知中心 / 语音识别等不应作为用户 App 出现）。
    /// 移植自 FineTune（GPL v3）。
    private static let systemDaemonPrefixes: [String] = [
        "com.apple.siri", "com.apple.Siri", "com.apple.assistant",
        "com.apple.audio", "com.apple.coreaudio", "com.apple.mediaremote",
        "com.apple.accessibility.heard", "com.apple.hearingd", "com.apple.voicebankingd",
        "com.apple.systemsound", "com.apple.FrontBoardServices", "com.apple.frontboard",
        "com.apple.springboard", "com.apple.notificationcenter",
        "com.apple.NotificationCenter", "com.apple.UserNotifications", "com.apple.usernotifications",
        "com.apple.SpeechRecognitionCore", "com.apple.speech",
        "com.apple.dictation", "com.apple.corespeech", "com.apple.CoreSpeech",
        "com.apple.VoiceControl", "com.apple.voicecontrol",
    ]

    private static let systemDaemonNames: [String] = [
        "systemsoundserverd", "systemsoundserv", "coreaudiod", "audiomxd",
        "speechrecognitiond", "dictationd", "corespeech",
    ]

    /// 用户会用来自主播放声音的 Apple 原生 App：即便 bundleID 属 com.apple.* 也放行，
    /// 其余 com.apple.* 进程（控制中心 / loginwindow / PowerChime / 辅助功能守护等）一律视为系统守护进程过滤。
    private static let appleUserAppAllowlist: Set<String> = [
        "com.apple.Music", "com.apple.Safari", "com.apple.QuickTimePlayerX",
        "com.apple.iTunes", "com.apple.FaceTime", "com.apple.TV",
        "com.apple.Podcasts", "com.apple.GarageBand", "com.apple.Photos",
        "com.apple.iMovie", "com.apple.VoiceMemos", "com.apple.MobileSMS",
    ]

    func start() {
        guard listenerBlock == nil else { return }
        listenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            .systemObject, &processListAddress, .main, listenerBlock!
        )
        if status != noErr {
            Log.error("[perapp] 无法添加进程列表监听: \(status)")
        }
        refresh()
        // 周期刷新作为安全网：CoreAudio 进程监听器在进程快速启停（退出 + 重开）时可能漏通知。
        startPeriodicRefresh()
    }

    func stop() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(.systemObject, &processListAddress, .main, block)
            listenerBlock = nil
        }
        removeAllProcessListeners()
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // 自适应降频：当前没有活跃音频 App 时，把兜底轮询从 10s 放宽到 30s，
                // 显著降低常驻 CPU 占用；一旦有 App 开始出声，逐进程 isRunning 监听会
                // 立即触发 refresh()，所以不会漏掉实时变化。
                let isEmpty = await MainActor.run { self?.activeApps.isEmpty ?? true }
                let interval: Double = isEmpty ? 30 : 10
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        processStateLock.lock()
        refreshGeneration += 1
        let generation = refreshGeneration
        processStateLock.unlock()
        let userEnabledBundles = self.alwaysIncludeBundleIDs

        // CoreAudio 枚举与进程解析较重，放到后台线程，避免阻塞主线程。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let processIDs: [AudioObjectID]
            do {
                processIDs = try CoreAudioHelpers.readProcessList()
            } catch {
                Log.error("[perapp] 读取进程列表失败: \(error.localizedDescription)")
                return
            }

            let runningApps = NSWorkspace.shared.runningApplications
            let runningAppsByPID: [pid_t: NSRunningApplication] = Dictionary(
                runningApps.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let myPID = ProcessInfo.processInfo.processIdentifier

            var appsByPID: [pid_t: AudioApp] = [:]

            for objectID in processIDs {
                guard let pid = CoreAudioHelpers.processPID(objectID), pid != myPID else { continue }

                // 逐进程「是否正在做音频 IO」闸门（FineTune 做法）：
                // 只保留此刻真正出声的进程对象，过滤掉仅挂着音频会话、实际没在播放的进程
                // （如后台工具、已暂停媒体的 App）。注意这必须**逐进程**判断，不能做全局闸。
                guard CoreAudioHelpers.processIsRunning(objectID) else { continue }

                // 直接同 PID 的 App（优先）；若它是 XPC/helper 而非真正的 .app，则向上找责任进程。
                let directApp = runningAppsByPID[pid]
                let isRealApp = directApp?.bundleURL?.pathExtension == "app"
                let resolvedApp = isRealApp ? directApp : self.findResponsibleApp(for: pid, in: runningAppsByPID)
                let parentPID = resolvedApp?.processIdentifier ?? pid
                let isHelper = parentPID != pid

                // 名称 / 图标 / bundleID 优先取自解析到的真实 App，兜底用 CoreAudio 原值。
                let name = resolvedApp?.localizedName
                    ?? CoreAudioHelpers.processBundleID(objectID)?.components(separatedBy: ".").last
                    ?? "Unknown"
                let icon = resolvedApp?.icon
                    ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                    ?? NSImage()
                let bundleID = resolvedApp?.bundleIdentifier ?? CoreAudioHelpers.processBundleID(objectID)

                // 过滤系统守护进程（Siri / coreaudio / 通知中心 / 语音识别等）。
                if Self.isSystemDaemon(bundleID: bundleID, name: name) { continue }

                // 必须要有真实宿主 App：解析不到 .app（且非用户手动开启）的游离音频进程
                // （如 "helper"、Chrome/XPC 的通用辅助进程）一律丢弃，不进列表、不留残留记录。
                // 否则这类无 bundleID 的进程会被错误归并成一张「helper」卡片，还可能被误隐藏。
                let hasRealHostApp = resolvedApp?.bundleURL?.pathExtension == "app"
                let isUserEnabled = bundleID.map { userEnabledBundles.contains($0) } ?? false
                if !hasRealHostApp, !isUserEnabled { continue }

                // 用户已在配置中手动开启（受控）的 App 不受任何限制，始终显示（逃生通道）。
                _ = isUserEnabled

                // 归并：helper/XPC 进程对象的 objectID 合并进其责任宿主 App 的条目，
                // 一个 App 只出一张卡片，且音量 tap 绑定完整对象集合（宿主 + helper）。
                if let existing = appsByPID[parentPID] {
                    var mergedIDs = existing.processObjectIDs
                    if !mergedIDs.contains(objectID) {
                        mergedIDs.append(objectID)
                        mergedIDs.sort()
                    }
                    appsByPID[parentPID] = AudioApp(
                        id: existing.id,
                        objectID: existing.objectID,
                        processObjectIDs: mergedIDs,
                        name: existing.name,
                        bundleID: existing.bundleID,
                        icon: existing.icon,
                        isHelperBacked: existing.isHelperBacked || isHelper
                    )
                } else {
                    appsByPID[parentPID] = AudioApp(
                        id: parentPID,
                        objectID: objectID,
                        processObjectIDs: [objectID],
                        name: name,
                        bundleID: bundleID,
                        icon: icon,
                        isHelperBacked: isHelper
                    )
                }
                _ = isUserEnabled
            }

            let sorted = appsByPID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // 更新逐进程 isRunning 监听（新增/移除），保证 app 启停出声能即时刷新。
            updateProcessListeners(for: processIDs)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var currentGeneration = 0
                self.processStateLock.lock()
                currentGeneration = self.refreshGeneration
                self.processStateLock.unlock()
                guard generation == currentGeneration else { return }
                // 变化检测：仅当 App 集合（pid + objectIDs）真正变化时才通知上层，
                // 避免 10s 周期轮询产生的无谓 UI / tap 重建抖动（移植自 FineTune）。
                // 必须在覆盖 self.activeApps 之前抓旧值，否则 oldSet/newSet 永远相等。
                let oldSet = Set(self.activeApps.map { AppFingerprint(pid: $0.id, objectIDs: $0.processObjectIDs) })
                self.activeApps = sorted
                let newSet = Set(sorted.map { AppFingerprint(pid: $0.id, objectIDs: $0.processObjectIDs) })
                if oldSet != newSet {
                    Log.info("[perapp] 活跃音频 App(\(sorted.count)个): \(sorted.isEmpty ? "（空）" : sorted.map { "\($0.name)(\($0.bundleID ?? "?"))" }.joined(separator: ", "))")
                    self.onAppsChanged?(sorted)
                }
            }
        }
    }

    /// 用 Apple 私有 API `responsibility_get_pid_responsible_for_pid` 获取进程的责任 PID
    /// （Activity Monitor 也用它来显示 XPC 服务的正确父 App）。dlsym 自 -1（RTLD_DEFAULT）即可，
    /// 无需 dlopen 特定框架。
    private func getResponsiblePID(for pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t
        let responsiblePID = unsafeBitCast(symbol, to: ResponsibilityFunc.self)(pid)
        return responsiblePID > 0 && responsiblePID != pid ? responsiblePID : nil
    }

    /// 为 helper / XPC 进程查找责任 App：先试 Apple 责任 PID API（Safari WebKit、系统 XPC 等），
    /// 失败再沿进程树向上走（Chrome / Brave helper 等）。
    private func findResponsibleApp(
        for pid: pid_t,
        in runningAppsByPID: [pid_t: NSRunningApplication]
    ) -> NSRunningApplication? {
        if let responsiblePID = getResponsiblePID(for: pid),
           let app = runningAppsByPID[responsiblePID],
           app.bundleURL?.pathExtension == "app" {
            return app
        }

        var currentPID = pid
        var visited = Set<pid_t>()
        while currentPID > 1 && !visited.contains(currentPID) {
            visited.insert(currentPID)
            if let app = runningAppsByPID[currentPID], app.bundleURL?.pathExtension == "app" {
                return app
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, currentPID]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
            let parentPID = info.kp_eproc.e_ppid
            if parentPID == currentPID { break }
            currentPID = parentPID
        }
        return nil
    }

    // MARK: - 逐进程 isRunning 监听

    private func updateProcessListeners(for processIDs: [AudioObjectID]) {
        let currentSet = Set(processIDs)
        // 在锁内只做集合读/写，避免与并发的 refresh() 互相破坏 `monitoredProcesses`。
        processStateLock.lock()
        let existing = monitoredProcesses
        monitoredProcesses = currentSet
        processStateLock.unlock()
        // 移除已消失进程的监听
        for objectID in existing.subtracting(currentSet) {
            removeProcessListener(for: objectID)
        }
        // 为新出现的进程添加监听
        for objectID in currentSet.subtracting(existing) {
            addProcessListener(for: objectID)
        }
    }

    private func addProcessListener(for objectID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)
        if status == noErr {
            processStateLock.lock()
            processListenerBlocks[objectID] = block
            processStateLock.unlock()
        } else {
            Log.error("[perapp] 无法添加 isRunning 监听 (\(objectID)): \(status)")
        }
    }

    private func removeProcessListener(for objectID: AudioObjectID) {
        processStateLock.lock()
        let block = processListenerBlocks.removeValue(forKey: objectID)
        processStateLock.unlock()
        guard let block else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
        // 容忍 kAudioHardwareBadObjectError(-66680)：监听时进程对象已销毁属正常情况。
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            Log.error("[perapp] 移除 isRunning 监听失败 (\(objectID)): \(status)")
        }
    }

    private func removeAllProcessListeners() {
        processStateLock.lock()
        let snapshot = processListenerBlocks
        monitoredProcesses.removeAll()
        processListenerBlocks.removeAll()
        processStateLock.unlock()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for (objectID, block) in snapshot {
            let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
            if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
                Log.error("[perapp] 移除 isRunning 监听失败 (\(objectID)): \(status)")
            }
        }
    }

    /// 是否系统守护进程（Siri / coreaudio / 通知中心 / 语音识别 / 无主通用辅助进程等）。
    /// 公开静态方法，供 UI 层复用（已隐藏区过滤、隐藏动作拦截）。
    static func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        if let bundleID {
            if Self.systemDaemonPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
            // 其余 com.apple.* 进程默认视为系统守护进程，仅放行白名单里的原生媒体 App。
            if bundleID.hasPrefix("com.apple."), !Self.appleUserAppAllowlist.contains(bundleID) {
                return true
            }
        }
        let lower = name.lowercased()
        return Self.systemDaemonNames.contains { lower.hasPrefix($0) }
    }
}
