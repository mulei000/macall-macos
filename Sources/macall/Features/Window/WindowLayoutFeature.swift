import AppKit
import Foundation
import Observation

// MARK: - 场景类型

/// 场景分两类：
/// - `.temporary` 临时场景：快捷键保存时自动生成，纯内存、进程退出即删，数量受上限约束。
/// - `.preset`    预设场景：用户命名并持久化，重启后仍在。
enum SceneKind: String, Codable {
    case temporary
    case preset
}

// MARK: - 数据模型

/// 一条被记录的窗口：足以在还原时定位并复位该窗口。
struct SavedWindow: Codable, Identifiable {
    let id: UUID
    /// App 的 bundle identifier（首选匹配键）。
    let bundleIdentifier: String
    /// App 本地化名称（bundleIdentifier 缺失时的兜底匹配键）。
    let appName: String
    /// 窗口标题（用于在某个 App 的多个窗口中甄别名）。
    let windowTitle: String
    /// 系统窗口 ID（若仍存活可精确匹配）。
    let cgWindowID: CGWindowID
    /// 窗口几何，AX 全局坐标系（原点在主导屏左上角）。
    let frame: CGRect
    /// 是否被最小化。
    let minimized: Bool
    /// 抓取时在该 App 窗口列表中的次序（作为最后的兜底匹配）。
    let order: Int

    var appLabel: String {
        appName.isEmpty ? (bundleIdentifier as String) : appName
    }
}

/// 一个布局快照（场景）。同一台机器上可保存多套（如「写作」「开会」）。
struct LayoutScene: Codable, Identifiable {
    let id: UUID
    var name: String
    var windows: [SavedWindow]
    let createdAt: Date
    var updatedAt: Date
    /// 是否置顶（仅对预设场景有意义；置顶的排在最前，方便常用场景一眼够到）。
    var pinned: Bool = false
    /// 场景类型：临时 / 预设。
    var kind: SceneKind

    var windowCount: Int { windows.count }

    /// 去重后的 App 名列表（按出现顺序），用于「是哪几个 App」展示。
    var appLabels: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for w in windows {
            let label = w.appLabel
            guard !label.isEmpty else { continue }
            if seen.insert(label).inserted { result.append(label) }
        }
        return result
    }

    /// 「App1、App2 …」拼接串。
    var appSummary: String { appLabels.joined(separator: "、") }

    init(id: UUID, name: String, windows: [SavedWindow],
         createdAt: Date, updatedAt: Date, pinned: Bool = false,
         kind: SceneKind = .preset) {
        self.id = id
        self.name = name
        self.windows = windows
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.kind = kind
    }

    // 手写解码：`pinned` / `kind` 都是后加的字段，缺省要能读老文件，
    // 否则升级后历史场景全丢。老文件没有 kind → 一律当预设处理（向后兼容）。
    private enum CodingKeys: String, CodingKey {
        case id, name, windows, createdAt, updatedAt, pinned, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        windows = try c.decode([SavedWindow].self, forKey: .windows)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        kind = try c.decodeIfPresent(SceneKind.self, forKey: .kind) ?? .preset
    }
}

// MARK: - 布局存储（单例，主线程）

/// 场景布局存储器：捕获当前所有常规 App 的窗口几何，按「场景」管理。
///
/// 拆分为两份：
/// - `presetScenes`：持久化到 `~/.config/macall/window_layouts.json`（顶部数组，向后兼容老格式）。
/// - `temporaryScenes`：纯内存，**启动即空、进程退出自动消失**，天然满足「临时场景退出即删」。
///
/// 复用 `AX`（AXWindowEngine）已有的 AX 读取 / 写入能力。
@Observable
final class LayoutStore {
    static let shared = LayoutStore()

    /// 预设场景（持久化）。
    private(set) var presetScenes: [LayoutScene] = []
    /// 临时场景（纯内存，退出即删）。
    private(set) var temporaryScenes: [LayoutScene] = []

    /// 最近一次「保存」（快捷键保存）的场景 ID，供「恢复」快捷键还原。
    var lastSavedSceneID: UUID?

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macall")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("window_layouts.json")
        load()
    }

    /// 最近一次保存的场景（用于保存后弹提示）。
    var lastSavedScene: LayoutScene? {
        guard let id = lastSavedSceneID else { return nil }
        return sceneByID(id)
    }

    /// 选择器 / 设置页展示用的合并列表：临时场景在前，预设在后（预设内部按置顶+原序）。
    var allScenes: [LayoutScene] {
        temporaryScenes + orderedPresets()
    }

    /// 预设（含置顶排序），供展示与还原。
    func orderedPresets() -> [LayoutScene] {
        let indexed = presetScenes.enumerated().map { ($0.offset, $0.element) }
        return indexed
            .sorted { a, b in
                if a.1.pinned != b.1.pinned { return a.1.pinned }
                return a.0 < b.0
            }
            .map(\.1)
    }

    private func sceneByID(_ id: UUID) -> LayoutScene? {
        temporaryScenes.first { $0.id == id } ?? presetScenes.first { $0.id == id }
    }

    // MARK: - 持久化（仅预设）

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LayoutScene].self, from: data)
        else { return }
        // 顶部数组格式与老文件一致；老场景无 kind 字段 → 解码为 .preset。
        presetScenes = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(presetScenes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 保存（快捷键）

    /// 把当前窗口布局存为一个新「临时场景」，并更新 lastSaved。
    /// 临时场景数量受设置项 `maxTemporaryScenes` 限制，超出丢弃最旧（仍在内存，不落盘）。
    func saveToTemporary() {
        let windows = captureCurrentLayout()
        let maxN = Configuration.load().maxTemporaryScenesClamped
        let index = temporaryScenes.count + 1
        let s = LayoutScene(
            id: UUID(),
            name: IadenteL10n.t("临时 \(index)", "Temp \(index)"),
            windows: windows, createdAt: Date(), updatedAt: Date(),
            pinned: false, kind: .temporary)
        temporaryScenes.append(s)
        if temporaryScenes.count > maxN {
            temporaryScenes.removeFirst()
        }
        lastSavedSceneID = s.id
        Log.info("[windowlayout] 已保存临时场景「\(s.name)」（\(windows.count) 个窗口），临时场景共 \(temporaryScenes.count) 个")
    }

    // MARK: - 恢复

    /// 还原「最近一次保存」的场景（快捷键 ⌃⌥L）。
    func restoreLastSaved() {
        guard let id = lastSavedSceneID else {
            Log.info("[windowlayout] 暂无已保存的场景可还原")
            return
        }
        restoreScene(id: id)
    }

    /// 按 ID 还原场景（临时或预设均可）。
    func restoreScene(id: UUID) {
        guard let scene = sceneByID(id) else { return }
        restore(scene: scene)
        Log.info("[windowlayout] 已还原场景「\(scene.name)」（\(scene.windows.count) 个窗口）")
    }

    // MARK: - 升级：临时 → 预设

    /// 把临时场景升级为预设：命名 + 持久化；升级后从临时列表移除。
    /// - Parameter name: 用户为预设取的名字（为空则沿用临时场景名）。
    func promoteToPreset(id: UUID, name: String) {
        guard let idx = temporaryScenes.firstIndex(where: { $0.id == id }) else { return }
        let tmp = temporaryScenes[idx]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? tmp.name : trimmed
        let preset = LayoutScene(
            id: UUID(),
            name: finalName,
            windows: tmp.windows,
            createdAt: Date(), updatedAt: Date(),
            pinned: false, kind: .preset)
        temporaryScenes.remove(at: idx)
        presetScenes.append(preset)
        save()
        lastSavedSceneID = preset.id
        Log.info("[windowlayout] 临时场景「\(tmp.name)」已升级为预设「\(finalName)」")
    }

    // MARK: - 预设增删改（设置页）

    /// 新建一个预设，并立即抓取当前窗口布局作为其内容。
    func addPreset(name: String) {
        let windows = captureCurrentLayout()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? IadenteL10n.t("新场景", "New Scene") : trimmed
        let s = LayoutScene(
            id: UUID(),
            name: finalName,
            windows: windows, createdAt: Date(), updatedAt: Date(),
            pinned: false, kind: .preset)
        presetScenes.append(s)
        save()
        Log.info("[windowlayout] 已新建预设「\(finalName)」（\(windows.count) 个窗口）")
    }

    func renameScene(id: UUID, name: String) {
        guard let idx = presetScenes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { presetScenes[idx].name = trimmed; save() }
    }

    /// 删除预设（可删到 0 个）。
    func deletePreset(id: UUID) {
        guard let idx = presetScenes.firstIndex(where: { $0.id == id }) else { return }
        presetScenes.remove(at: idx)
        if lastSavedSceneID == id { lastSavedSceneID = nil }
        save()
    }

    /// 删除临时场景。
    func deleteTemporary(id: UUID) {
        guard let idx = temporaryScenes.firstIndex(where: { $0.id == id }) else { return }
        temporaryScenes.remove(at: idx)
        if lastSavedSceneID == id { lastSavedSceneID = nil }
    }

    /// 切换预设置顶。
    func togglePinned(id: UUID) {
        guard let idx = presetScenes.firstIndex(where: { $0.id == id }) else { return }
        presetScenes[idx].pinned.toggle()
        save()
    }

    // MARK: - 捕获（主线程）

    /// 抓取当前所有常规 App 的真实窗口几何。
    func captureCurrentLayout() -> [SavedWindow] {
        var result: [SavedWindow] = []
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        for app in apps {
            let wins = AX.actualWindows(of: app)
            for (idx, win) in wins.enumerated() {
                guard let frame = AX.frame(of: win) else { continue }
                result.append(SavedWindow(
                    id: UUID(),
                    bundleIdentifier: app.bundleIdentifier ?? "",
                    appName: app.localizedName ?? "",
                    windowTitle: AX.title(of: win) ?? "",
                    cgWindowID: AX.cgWindowID(of: win) ?? 0,
                    frame: frame,
                    minimized: AX.isMinimized(win),
                    order: idx))
            }
        }
        return result
    }

    // MARK: - 还原（主线程）

    func restore(scene: LayoutScene) {
        var missingBundles = Set<String>()
        for entry in scene.windows {
            if !restoreEntry(entry), !entry.bundleIdentifier.isEmpty {
                missingBundles.insert(entry.bundleIdentifier)
            }
        }
        guard !missingBundles.isEmpty else { return }
        // 尽力启动缺失的 App，稍后重试还原它们的窗口（窗口需要时间创建）。
        for bid in missingBundles {
            _ = NSWorkspace.shared.launchApplication(
                withBundleIdentifier: bid, options: [],
                additionalEventParamDescriptor: nil, launchIdentifier: nil)
        }
        let retry = scene.windows.filter { missingBundles.contains($0.bundleIdentifier) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            for entry in retry { _ = self.restoreEntry(entry) }
        }
    }

    private func runningApp(for entry: SavedWindow) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if !entry.bundleIdentifier.isEmpty,
           let a = apps.first(where: { $0.bundleIdentifier == entry.bundleIdentifier }) { return a }
        return apps.first(where: { $0.localizedName == entry.appName })
    }

    private func matchWindow(in wins: [AXUIElement], entry: SavedWindow) -> AXUIElement? {
        // 1) 系统窗口 ID 仍存活 → 精确匹配。
        if entry.cgWindowID != 0,
           let w = wins.first(where: { AX.cgWindowID(of: $0) == entry.cgWindowID }) { return w }
        // 2) 标题精确匹配。
        if !entry.windowTitle.isEmpty {
            if let w = wins.first(where: { (AX.title(of: $0) ?? "") == entry.windowTitle }) { return w }
            // 3) 标题包含（忽略大小写）。
            let low = entry.windowTitle.lowercased()
            if let w = wins.first(where: { (AX.title(of: $0) ?? "").lowercased().contains(low) }) {
                return w
            }
        }
        // 4) 兜底：按抓取时的次序。
        if entry.order < wins.count { return wins[entry.order] }
        return wins.last
    }

    /// 还原单条窗口：定位 App → 匹配窗口 → 写回几何与最小化状态。成功返回 true。
    private func restoreEntry(_ entry: SavedWindow) -> Bool {
        guard let app = runningApp(for: entry) else { return false }
        guard let wins = AX.windows(of: app) else { return false }
        guard let win = matchWindow(in: wins, entry: entry) else { return false }
        let vf = AX.visibleFrameForWindow(win)
        AX.setFrameSnapped(win, target: entry.frame, visibleFrame: vf)
        AX.setMinimized(win, entry.minimized)
        return true
    }
}

// MARK: - 功能

/// 场景布局记忆：后台不轮询；仅在用户触发时抓取当前窗口几何，按「场景」保存 / 还原。
///
/// 快捷键：
/// - ⌃⌥S 保存：抓取当前布局存为「临时场景」，并提示已保存。
/// - ⌃⌥L 还原：还原最近一次保存的场景。
/// - ⌃⌥P 弹出场景选择器（左名右图，类似 tab 预览），可还原 / 升级为预设 / 删除临时场景。
final class WindowLayoutFeature: Feature {
    let id = "windowlayout"
    var title: String { IadenteL10n.t("场景布局", "Scene Layout") }
    let category = FeatureCategory.window
    var enabledByDefault: Bool = true

    private var context: AppContext?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[windowlayout] 已安装：⌃⌥S 保存为临时场景，⌃⌥L 还原最近保存，⌃⌥P 弹出场景选择器")
    }

    private func bindHotkey(using config: Configuration) {
        let defaults = Configuration.defaultHotkeys()
        let saveCombo = config.hotkeys["layout.save"]?.toCombo()
            ?? defaults["layout.save"]!.toCombo()
        let restoreCombo = config.hotkeys["layout.restore"]?.toCombo()
            ?? defaults["layout.restore"]!.toCombo()
        let pickerCombo = config.hotkeys["layout.picker"]?.toCombo()
            ?? defaults["layout.picker"]!.toCombo()
        context?.hotkeys.bind(
            featureId: id, action: "save", configKey: "layout.save", defaultCombo: saveCombo)
        context?.hotkeys.bind(
            featureId: id, action: "restore", configKey: "layout.restore", defaultCombo: restoreCombo)
        context?.hotkeys.bind(
            featureId: id, action: "picker", configKey: "layout.picker", defaultCombo: pickerCombo)
    }

    func handle(action: String) {
        switch action {
        case "save":
            LayoutStore.shared.saveToTemporary()
            if let s = LayoutStore.shared.lastSavedScene {
                SceneToast.shared.show(
                    IadenteL10n.t("已保存到临时场景：", "Saved to temporary scene: ") + s.name)
            }
        case "restore":
            LayoutStore.shared.restoreLastSaved()
        case "picker":
            Task { @MainActor in ScenePickerController.shared.toggle() }
        default:
            break
        }
    }

    func reload(config: Configuration) {
        bindHotkey(using: config)
    }

    func uninstall() {
        Log.info("[windowlayout] 已卸载")
    }
}
