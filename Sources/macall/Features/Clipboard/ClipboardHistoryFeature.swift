import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 数据模型

enum ClipboardKind: String, Codable {
    case text
    case image
    case file
}

/// 剪贴板历史的分类筛选。← / → 在四个值之间循环切换。
enum ClipboardCategory: CaseIterable, Identifiable {
    case all, text, image, file

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return IadenteL10n.t("全部", "All")
        case .text: return IadenteL10n.t("文本", "Text")
        case .image: return IadenteL10n.t("图片", "Image")
        case .file: return IadenteL10n.t("文件", "File")
        }
    }

    /// 该分类是否匹配某条记录。
    var matches: (ClipboardItem) -> Bool {
        switch self {
        case .all: return { _ in true }
        case .text: return { $0.kind == .text }
        case .image: return { $0.kind == .image }
        case .file: return { $0.kind == .file }
        }
    }
}

/// 一条剪贴板历史记录。可直接 JSON 持久化（图片以 PNG Data 存储）。
struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: ClipboardKind
    let text: String
    /// 图片内容（PNG）。仅 kind == .image 时有值。
    let imageData: Data?
    /// 文件路径列表。仅 kind == .file 时有值。
    let filePaths: [String]
    let timestamp: Date
    let appName: String
    /// 文件类型（UTI 字符串，如 "com.adobe.pdf"）。仅 kind == .file 时有值。
    /// 老版本记录解码时为 nil，UI 端回退为「未知」。
    let fileUTI: String?
    /// 文件大小（字节）。仅 kind == .file 时有值。
    let fileSize: Int64?

    /// 内容指纹，用于去重（避免重复记录同一条）。
    var fingerprint: String {
        switch kind {
        case .text: return "text:" + text
        case .image: return "image:" + (imageData?.base64EncodedString().prefix(64) ?? "")
        case .file: return "file:" + filePaths.joined(separator: "|")
        }
    }

    /// 列表里展示的简短预览文本。
    var previewText: String {
        switch kind {
        case .text:
            let trimmed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return String(trimmed.prefix(120))
        case .image: return IadenteL10n.t("[图片]", "[Image]")
        case .file:
            return filePaths.last.map { URL(fileURLWithPath: $0).lastPathComponent } ?? IadenteL10n.t("[文件]", "[File]")
        }
    }

    var detailText: String {
        switch kind {
        case .text:
            let lines = text.components(separatedBy: .newlines)
            return lines.prefix(3).joined(separator: "  ")
        case .image: return IadenteL10n.t("图片剪贴板", "Image clipboard")
        case .file: return filePaths.joined(separator: ", ")
        }
    }
}

// MARK: - 历史存储（单例，主线程）

/// 剪贴板历史存储器：轮询系统剪贴板变化并去重记录，持久化到
/// `~/.config/macall/clipboard_history.json`。与窗口类/监控类参考项目无关，
/// 是 macall 的净新增模块。
@Observable
final class ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    private(set) var items: [ClipboardItem] = []

    /// 最多保留多少条（置顶项不占配额）。由设置页写入，改动后立即生效。
    var maxItems = 200 {
        didSet { guard maxItems != oldValue else { return }; enforceCap(); save() }
    }
    /// 保留天数，0 表示永久。
    var retentionDays = 0 {
        didSet { guard retentionDays != oldValue else { return }; purgeExpired() }
    }
    /// 是否记录图片类剪贴板。
    var keepImages = true
    /// 是否记录「拷贝的文件 / 文件夹」。
    var keepFiles = true

    /// 置顶（收藏）条目，**按置顶时间倒序**（最近置顶的在最前）。
    /// 用数组而不是集合，是因为用户要求「置顶项之间按置顶时间排序」；
    /// 集合没有顺序，每次渲染都可能换位置。
    private(set) var pinnedOrder: [UUID] = []

    /// 兼容旧调用点的集合视图（判定「是否置顶」用它，O(n) 但 n 很小）。
    var pinnedIDs: Set<UUID> { Set(pinnedOrder) }

    /// 上次读取到的剪贴板 changeCount，用于跳过无变化的轮询。
    var lastChangeCount: Int = -1

    private let fileURL: URL
    private let pinsURL: URL

    private init() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/macall")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("clipboard_history.json")
        self.pinsURL = dir.appendingPathComponent("clipboard_pins.json")
        load()
        loadPins()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else { return }
        items = Array(decoded.prefix(maxItems))
    }

    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 轮询调用：若剪贴板发生变化，抓取并去重入栈。
    func captureCurrent() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        if change == lastChangeCount { return }
        lastChangeCount = change

        guard let item = Self.readFromPasteboard(pb) else { return }
        if item.kind == .image, !keepImages { return }
        if item.kind == .file, !keepFiles { return }
        if let top = items.first, top.fingerprint == item.fingerprint { return }
        items.insert(item, at: 0)
        purgeExpired(saving: false)
        enforceCap()
        save()
    }

    /// 容量淘汰：从尾部移除，但跳过置顶项；若剩余项均为置顶且超出上限则保留。
    private func enforceCap() {
        // pinnedIDs 是计算属性，循环里反复取会每轮重建 Set —— 先抓一份快照。
        let pins = pinnedIDs
        var i = items.count - 1
        while items.count > maxItems, i >= 0 {
            if !pins.contains(items[i].id) {
                items.remove(at: i)
            }
            i -= 1
        }
    }

    /// 时效淘汰：删掉超过 `retentionDays` 天的非置顶条目（0 = 永久保留）。
    func purgeExpired(saving: Bool = true) {
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let before = items.count
        let pins = pinnedIDs
        items.removeAll { $0.timestamp < cutoff && !pins.contains($0.id) }
        if saving, items.count != before { save() }
    }

    /// 历史文件在磁盘上的体积（字节），设置页用于展示。
    var storageBytes: Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    private static func readFromPasteboard(_ pb: NSPasteboard) -> ClipboardItem? {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let now = Date()

        // 1) 文件（优先级最高）
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL],
           !urls.isEmpty
        {
            let paths = urls.compactMap { $0.path }
            guard !paths.isEmpty else { return nil }
            let meta = Self.readFileMeta(paths)
            return ClipboardItem(
                id: UUID(), kind: .file, text: "", imageData: nil,
                filePaths: paths, timestamp: now, appName: app,
                fileUTI: meta.uti, fileSize: meta.size)
        }

        // 2) 图片
        if let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            let png = downscaleToPNG(raw)
            return ClipboardItem(
                id: UUID(), kind: .image, text: "", imageData: png,
                filePaths: [], timestamp: now, appName: app,
                fileUTI: nil, fileSize: nil)
        }

        // 3) 文本
        if let str = pb.string(forType: .string), !str.isEmpty {
            return ClipboardItem(
                id: UUID(), kind: .text, text: str, imageData: nil,
                filePaths: [], timestamp: now, appName: app,
                fileUTI: nil, fileSize: nil)
        }

        return nil
    }

    /// 取复制文件的首个路径的 UTI 与大小（用于面板展示「类型 · 大小」）。
    /// 多文件时只取第一个；其余文件的「等 N 项」由 UI 处理。
    private static func readFileMeta(_ paths: [String]) -> (uti: String?, size: Int64?) {
        guard let first = paths.first else { return (nil, nil) }
        let url = URL(fileURLWithPath: first)
        var uti: String? = nil
        if let vals = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let ct = vals.contentType
        {
            uti = ct.identifier
        }
        var size: Int64? = nil
        if let attrs = try? FileManager.default.attributesOfItem(atPath: first),
           let s = attrs[.size] as? NSNumber
        {
            size = s.int64Value
        }
        return (uti, size)
    }

    /// 把大图缩放后存为 PNG，避免历史文件膨胀。
    private static func downscaleToPNG(_ data: Data) -> Data {
        guard let img = NSImage(data: data) else { return data }
        let maxDim: CGFloat = 600
        var (w, h) = (img.size.width, img.size.height)
        if max(w, h) > maxDim {
            let scale = maxDim / max(w, h)
            w *= scale; h *= scale
        } else {
            return data
        }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { return data }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? data
    }

    func moveToTop(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        save()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        pinnedOrder.removeAll()
        save()
        savePins()
    }

    // MARK: - 置顶 / 收藏

    func isPinned(_ item: ClipboardItem) -> Bool {
        pinnedOrder.contains(item.id)
    }

    func isPinned(id: UUID) -> Bool {
        pinnedOrder.contains(id)
    }

    /// 面板 / 管理器统一使用的展示顺序：
    /// **置顶组在前**（按置顶时间倒序，最近置顶的最靠上），非置顶组在后（按入栈时间）。
    var displayItems: [ClipboardItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = pinnedOrder.compactMap { byID[$0] }
        let pins = Set(pinnedOrder)
        let rest = items.filter { !pins.contains($0.id) }
        return pinned + rest
    }

    /// 面板 / 键盘导航共用的过滤：在「置顶组在前」的展示顺序上，叠加
    /// 分类与搜索词过滤。两者都走这一份，保证选中索引与渲染完全一致。
    func filteredItems(query: String, category: ClipboardCategory) -> [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return displayItems.filter { item in
            guard category.matches(item) else { return false }
            if q.isEmpty { return true }
            return item.previewText.localizedCaseInsensitiveContains(q)
                || item.detailText.localizedCaseInsensitiveContains(q)
                || item.appName.localizedCaseInsensitiveContains(q)
        }
    }

    func togglePin(_ item: ClipboardItem) { setPinned(id: item.id, !isPinned(id: item.id)) }

    /// 置顶 / 取消置顶单条。
    ///
    /// 取消置顶时会把这条**移动到非置顶组的第一位**（用户明确要求的行为），
    /// 否则它会掉回原来的时间位置，看起来就像“消失了”。
    func setPinned(id: UUID, _ pinned: Bool) {
        if pinned {
            guard !pinnedOrder.contains(id) else { return }
            pinnedOrder.insert(id, at: 0)   // 最近置顶的排最前
        } else {
            guard let idx = pinnedOrder.firstIndex(of: id) else { return }
            pinnedOrder.remove(at: idx)
            // 挪到非置顶组的头部：先摘出来，再插到「最后一个仍置顶的条目」之后。
            if let cur = items.firstIndex(where: { $0.id == id }) {
                let entry = items.remove(at: cur)
                let pins = Set(pinnedOrder)
                var insertAt = 0
                while insertAt < items.count, pins.contains(items[insertAt].id) { insertAt += 1 }
                items.insert(entry, at: insertAt)
                save()
            }
        }
        savePins()
    }

    /// 批量置顶 / 取消置顶（管理器的「置顶所选」用）。
    func setPinned(ids: [UUID], _ pinned: Bool) {
        for id in ids { setPinned(id: id, pinned) }
    }

    /// 批量删除（管理器的「删除所选」用）。
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        pinnedOrder.removeAll { ids.contains($0) }
        save()
        savePins()
    }

    private func loadPins() {
        guard let data = try? Data(contentsOf: pinsURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        // 老版本写的是无序集合序列化出来的数组，顺序不可靠但不影响功能，
        // 用户重新置顶一次即可得到正确的时间序。
        pinnedOrder = decoded.compactMap { UUID(uuidString: $0) }
    }

    private func savePins() {
        let arr = pinnedOrder.map { $0.uuidString }
        guard let data = try? JSONEncoder().encode(arr) else { return }
        try? data.write(to: pinsURL, options: .atomic)
    }
}

// MARK: - 功能

/// 剪贴板历史：后台轮询系统剪贴板，记录文本/图片/文件，全局快捷键唤起面板，
/// 点击即复制并自动粘贴（合成 ⌘V）。净新增模块，不依赖任何参考项目。
final class ClipboardHistoryFeature: Feature {
    let id = "clipboard"
    let title = IadenteL10n.t("剪贴板历史", "Clipboard History")
    let category = FeatureCategory.other
    var enabledByDefault: Bool = true

    private var context: AppContext?
    private var timer: Timer?
    private var panel: ClipboardHistoryPanelController?
    private var previousApp: NSRunningApplication?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        applyStoreSettings(context.config)
        // 同步一次 changeCount，避免启动瞬间把当前剪贴板误记为一条。
        ClipboardHistoryStore.shared.lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in
                ClipboardHistoryStore.shared.captureCurrent()
            }
        }
        Log.info("[clipboard] 已安装：开始监听系统剪贴板（⌘⇧V 唤起）")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["clipboard.show"]?.toCombo()
            ?? Configuration.defaultHotkeys()["clipboard.show"]!.toCombo()
        context?.hotkeys.bind(
            featureId: id, action: "show", configKey: "clipboard.show", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "show" { togglePanel() }
    }

    func reload(config: Configuration) {
        bindHotkey(using: config)
        applyStoreSettings(config)
    }

    /// 把「历史管理」里的容量 / 时效 / 是否记图片同步到存储器。
    private func applyStoreSettings(_ config: Configuration) {
        let store = ClipboardHistoryStore.shared
        store.keepImages = config.clipboardKeepImages
        store.keepFiles = config.clipboardKeepFiles
        store.maxItems = max(10, min(1000, config.clipboardMaxItems))
        store.retentionDays = max(0, config.clipboardRetentionDays)
        store.purgeExpired()
    }

    func uninstall() {
        timer?.invalidate()
        timer = nil
        closePanel()
        Log.info("[clipboard] 已卸载：停止监听系统剪贴板")
    }

    func menuItems() -> [NSMenuItem]? {
        let item = NSMenuItem(
            title: IadenteL10n.t("剪贴板历史", "Clipboard History"),
            action: #selector(menuShow), keyEquivalent: "")
        item.target = self
        return [item]
    }

    @objc private func menuShow() { togglePanel() }

    // MARK: - 面板

    private func togglePanel() {
        if panel != nil { closePanel(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let openShortcut: String = {
            let spec = context?.config.hotkeys["clipboard.show"]
                ?? Configuration.defaultHotkeys()["clipboard.show"]
            guard let spec else { return "⌘⇧V" }
            return hotkeyDisplayString(spec)
        }()
        let p = ClipboardHistoryPanelController()
        p.openShortcut = openShortcut
        p.onPick = { [weak self] item in self?.paste(item) }
        p.onClose = { [weak self] in
            self?.panel = nil
        }
        p.show()
        panel = p
    }

    private func closePanel() {
        panel?.close()
        panel = nil
    }

    // MARK: - 粘贴

    private func paste(_ item: ClipboardItem) {
        MainActor.assumeIsolated {
            ClipboardHistoryStore.shared.moveToTop(item)
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text, forType: .string)
        case .image:
            if let d = item.imageData { pb.setData(d, forType: .png) }
        case .file:
            pb.writeObjects(item.filePaths.map { NSURL(fileURLWithPath: $0) })
        }

        closePanel()

        // 还原到此前的前台 App，再合成 ⌘V 自动粘贴。
        if let app = previousApp {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.postCommandV() }
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9 /* kVK_ANSI_V */, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = CGEventFlags.maskCommand
        up?.flags = CGEventFlags.maskCommand
        down?.post(tap: CGEventTapLocation.cghidEventTap)
        up?.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
