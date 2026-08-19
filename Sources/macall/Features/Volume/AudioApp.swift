import AppKit
import CoreAudio
import Foundation

// MARK: - 正在发声的 App 模型

/// 表示一个当前正在产生音频的进程（可单独调音量 / 静音 / 路由）。
/// 移植自 FineTune 的 AudioApp，按 macall 风格精简。
struct AudioApp: Identifiable, Hashable {
    /// 进程 PID（列表内唯一，取责任进程 / 宿主 App 的 PID）。逐 App 音频以 bundleID 为持久键（见 `persistenceKey`）。
    let id: pid_t
    /// 主进程对象（用于显示与回退）；`processObjectIDs` 才是建 tap 用的完整对象集合（含归并的 helper）。
    let objectID: AudioObjectID
    /// 该 App 所有发声的音频进程对象（宿主 + helper/XPC，如 Safari 的 WebKit 进程、Chrome 的 helper）。
    /// 建 tap 时用整个数组做 stereoMixdown，保证 helper 进程的声音也被正确拦截。
    let processObjectIDs: [AudioObjectID]
    let name: String
    let bundleID: String?
    let icon: NSImage?
    /// 是否由 helper / XPC 进程支撑（用于调试与排序，无功能影响）。
    let isHelperBacked: Bool

    init(id: pid_t, objectID: AudioObjectID, processObjectIDs: [AudioObjectID] = [],
         name: String, bundleID: String?, icon: NSImage?, isHelperBacked: Bool = false) {
        self.id = id
        self.objectID = objectID
        self.processObjectIDs = processObjectIDs.isEmpty ? [objectID] : processObjectIDs
        self.name = name
        self.bundleID = bundleID
        self.icon = icon
        self.isHelperBacked = isHelperBacked
    }

    /// 配置持久化的键：优先用 bundleID，无则用 pid，保证 App 重启后仍对应同一设置。
    var persistenceKey: String { bundleID ?? "pid:\(id)" }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool { lhs.id == rhs.id }
}
