import AppKit
import Foundation
import SwiftUI

/// 剪贴板历史面板的选中状态。用 @Observable 单例承载，便于键盘监听器
/// （在控制器里）与 SwiftUI 视图共享同一份选中索引。
@Observable
final class ClipboardPanelState {
    var selectedIndex: Int = 0
    /// 搜索词（与视图双向绑定，键盘导航需读取以对齐过滤结果）。
    var query: String = ""
    /// 当前分类（← / → 切换）。
    var category: ClipboardCategory = .all
    /// 搜索模式开关：true 时搜索框聚焦、可输入；false 时为导航模式，
    /// 方向键直接控制选择/分类（取代原先依据 firstResponder 的判断）。
    var searchFocused: Bool = false
}

/// 剪贴板历史面板：NSWindow + SwiftUI，由全局快捷键唤起。
/// 点击条目即「复制并自动粘贴」（由 ClipboardHistoryFeature.paste 完成）。
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    var onPick: ((ClipboardItem) -> Void)?
    var onClose: (() -> Void)?
    /// 唤起面板的快捷键字符串，由 Feature 根据用户自定义配置传入（默认 ⌘⇧V）。
    var openShortcut: String = "⌘⇧V"

    private var window: NSWindow?
    private let state = ClipboardPanelState()
    /// 面板显示期间的本地键盘监听（比窗口 keyDown 可靠，且不受 firstResponder 影响）。
    private var keyMonitor: Any?

    func moveSelection(_ delta: Int) {
        let count = ClipboardHistoryStore.shared.filteredItems(
            query: state.query, category: state.category).count
        guard count > 0 else { return }
        state.selectedIndex = (state.selectedIndex + delta + count) % count
    }

    func commitSelection() {
        let items = ClipboardHistoryStore.shared.filteredItems(
            query: state.query, category: state.category)
        guard items.indices.contains(state.selectedIndex) else { return }
        onPick?(items[state.selectedIndex])
    }

    /// ← / → 在四个分类间循环切换，并重置选中到第一条。
    func moveCategory(_ delta: Int) {
        let all = ClipboardCategory.allCases
        guard let idx = all.firstIndex(of: state.category) else { return }
        state.category = all[(idx + delta + all.count) % all.count]
        state.selectedIndex = 0
    }

    /// 面板键盘处理（由 installKeyMonitor 的本地监听转发）。
    /// 返回 true 表示本事件已被消费（nil，不再下发）；false 则原样下发（如搜索框内输入）。
    /// - 导航模式（searchFocused == false）：↑↓ 选择 / ←→ 分类 / ↵ 粘贴 / Esc 关闭；
    ///   方向键一定生效，不再被搜索框焦点吞掉。
    /// - 搜索模式（searchFocused == true）：Space 正常输入空格；Esc 先退出搜索回到导航；
    ///   方向键交还文本框（移动文字光标）；↵ 仍粘贴当前选中项。
    func handleKey(_ event: NSEvent) -> Bool {
        let searching = state.searchFocused
        switch event.keyCode {
        case 49:                                                          // space
            if searching { return false }                                 // 搜索模式：空格正常输入
            state.searchFocused = true                                    // 导航模式：进入搜索
            return true
        case 126 where !searching: moveSelection(-1); return true         // ↑
        case 125 where !searching: moveSelection(1); return true          // ↓
        case 123 where !searching: moveCategory(-1); return true          // ←
        case 124 where !searching: moveCategory(1); return true           // →
        case 36, 76: commitSelection(); return true                       // ↵ / 小键盘回车
        case 53:                                                          // esc
            if searching { state.searchFocused = false; return true }     // 先退出搜索
            close(); return true                                          // 再按才关闭面板
        default: return false
        }
    }

    func show() {
        state.selectedIndex = 0
        state.searchFocused = false   // 默认进入导航模式，方向键直接生效（不抢搜索框焦点）
        let hosting = NSHostingController(
            rootView: ClipboardHistoryView(state: state, openShortcut: openShortcut, onPick: { [weak self] item in
                self?.onPick?(item)
            })
        )
        let newWindow = ClipboardHistoryPanelWindow(contentViewController: hosting)
        newWindow.title = IadenteL10n.t("剪贴板历史", "Clipboard History")
        newWindow.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.appearance = Defaults[.appearanceMode].nsAppearance
        newWindow.contentView?.wantsLayer = true
        newWindow.contentView?.layer?.cornerRadius = 14
        newWindow.contentView?.layer?.masksToBounds = true
        newWindow.setContentSize(NSSize(width: 440, height: 540))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
        installKeyMonitor()
        // SwiftUI 可能自动把搜索框设为第一响应者并把 searchFocused 翻成 true，
        // 下一轮运行强制取消聚焦，确保方向键直接进入「导航模式」而非被搜索框吃掉。
        DispatchQueue.main.async { [weak self, weak newWindow] in
            newWindow?.makeFirstResponder(nil)
            self?.state.searchFocused = false
        }
    }

    func close() {
        removeKeyMonitor()
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            onClose?()
        }
    }

    /// 点击窗口外部 / 切到别的 App 时失焦即关闭（用户要求：点到别处就消失）。
    /// 仅在 macall 真的失去活跃态时关闭，App 内瞬时失焦（如激活过程中的跳动）不误关。
    func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !NSApp.isActive else { return }
            self.close()
        }
    }

    /// 面板成为关键窗口时（含打开/重新激活），再次确保搜索框未聚焦、
    /// searchFocused 复位为 false，避免 SwiftUI 自动聚焦把方向键关掉。
    func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let w = window else { return }
            if w.firstResponder is NSTextView || w.firstResponder is NSSearchField {
                w.makeFirstResponder(nil)
            }
            state.searchFocused = false
        }
    }

    // MARK: 本地键盘监听

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window != nil, self.window?.isKeyWindow == true else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - SwiftUI 视图

private struct ClipboardHistoryView: View {
    @Default(.appLanguage) private var appLanguage
    @Environment(\.colorScheme) private var colorScheme
    /// 搜索框焦点（与 state.searchFocused 双向同步）：true 时搜索框聚焦可输入。
    @FocusState private var searchFocused: Bool

    @Bindable var state: ClipboardPanelState
    let openShortcut: String
    let onPick: (ClipboardItem) -> Void

    /// 已经是「置顶组在前、按置顶时间倒序」的顺序，由 store 统一裁决，
    /// 面板与管理器共用同一份排序逻辑，避免两处显示顺序对不上。
    private var items: [ClipboardItem] {
        ClipboardHistoryStore.shared.displayItems
    }

    /// 当前分类 + 搜索词过滤后的列表（与键盘导航共用 store.filteredItems）。
    private var filtered: [ClipboardItem] {
        ClipboardHistoryStore.shared.filteredItems(query: state.query, category: state.category)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(.primary.opacity(0.11))

            if items.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatchState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                row(item: item, index: index)
                                    .id(item.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: state.selectedIndex) { _, _ in
                        if let sel = filtered[safe: state.selectedIndex] {
                            proxy.scrollTo(sel.id, anchor: .center)
                        }
                    }
                }
            }

            Divider().background(.primary.opacity(0.11))

            footer
        }
        .frame(width: 440, height: 540)
        .background(IadenteWindowBackdrop())
        .tint(IadenteTheme.jade)
        .onChange(of: state.query) { _, _ in
            state.selectedIndex = 0
        }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                IadenteIconBadge(
                    icon: "doc.on.clipboard",
                    colors: [IadenteTheme.ocean, IadenteTheme.sky],
                    size: 30
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(IadenteL10n.t("剪贴板历史", "Clipboard History"))
                        .font(.system(size: 14, weight: .semibold))
                Text(IadenteL10n.t("点击条目即粘贴 · \(openShortcut) 唤起 · 空格搜索 · ↑↓ 选择 · ←→ 分类 · ↵ 粘贴 · Esc 关闭",
                                   "Click to paste · \(openShortcut) to open · Space to search · ↑↓ navigate · ←→ category · ↵ paste · Esc close"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(IadenteL10n.t("按空格搜索", "Press Space to search"), text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
            }
            // 双向同步搜索框焦点：用户手动点进/点出 → 反映到 state.searchFocused；
            // 控制器（按空格 / Esc）改 state.searchFocused → 驱动 @FocusState 聚焦/失焦。
            .onChange(of: searchFocused) { _, newValue in
                state.searchFocused = newValue
            }
            .onChange(of: state.searchFocused) { _, wanted in
                if wanted != searchFocused { searchFocused = wanted }
            }

            // 分类栏：全部 / 文本 / 图片 / 文件；选中态 ocean 蓝，每段显示该类条数（按全部数据计）。
            HStack(spacing: 6) {
                ForEach(ClipboardCategory.allCases) { cat in
                    let cnt = count(for: cat)
                    Button {
                        state.searchFocused = false   // 鼠标点分类 → 退出搜索，方向键立即可用
                        state.category = cat
                        state.selectedIndex = 0
                    } label: {
                        HStack(spacing: 4) {
                            Text(cat.title)
                                .font(.system(size: 11.5, weight: .medium))
                            Text("\(cnt)")
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.7)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background {
                            if state.category == cat {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(IadenteTheme.ocean)
                            } else {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05))
                            }
                        }
                        .foregroundStyle(state.category == cat ? Color.white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    // MARK: row

    private func row(item: ClipboardItem, index: Int) -> some View {
        let selected = index == state.selectedIndex
        return Button {
            state.searchFocused = false   // 鼠标点列表 → 退出搜索，方向键立即可用
            if index == state.selectedIndex {
                onPick(item)            // 已选中 → 粘贴（enter）
            } else {
                state.selectedIndex = index   // 未选中 → 选中并放大预览
            }
        } label: {
            HStack(spacing: 11) {
                leadingContent(item: item, selected: selected)

                VStack(alignment: .leading, spacing: 2) {
                    if item.kind == .file {
                        // 文件：文件名（加粗）+「等 N 项」，第二行「类型 · 大小 · 时间」。
                        let name = item.filePaths.first
                            .map { URL(fileURLWithPath: $0).lastPathComponent }
                            ?? IadenteL10n.t("[文件]", "[File]")
                        let more = item.filePaths.count > 1
                            ? IadenteL10n.t(" 等 \(item.filePaths.count) 项",
                                           " +\(item.filePaths.count) more")
                            : ""
                        Text(name + more)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .foregroundStyle(selected ? Color.white : .primary)
                        HStack(spacing: 6) {
                            Text([item.fileTypeLabel, item.fileSizeLabel]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10))
                            Text("· \(item.timestampText)")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    } else {
                        Text(item.previewText.isEmpty ? item.detailText : item.previewText)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(selected ? Color.white : .primary)
                        HStack(spacing: 6) {
                            Text(item.timestampText)
                                .font(.system(size: 10))
                            if !item.appName.isEmpty {
                                Text("· \(item.appName)")
                                    .font(.system(size: 10))
                            }
                        }
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    }
                }
                Spacer(minLength: 0)

                Button {
                    ClipboardHistoryStore.shared.togglePin(item)
                } label: {
                    let pinned = ClipboardHistoryStore.shared.isPinned(item)
                    Image(systemName: pinned ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(
                            pinned ? Color.yellow
                                : (selected ? Color.white.opacity(0.85) : Color.secondary))
                }
                .buttonStyle(.plain)
                .help(IadenteL10n.t("置顶 / 取消置顶", "Pin / unpin"))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(IadenteTheme.ocean)
                } else {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 行首内容：图片显示缩略图（选中放大到 80，平时 44），文本/文件显示类型图标。
    @ViewBuilder
    private func leadingContent(item: ClipboardItem, selected: Bool) -> some View {
        switch item.kind {
        case .image:
            if let img = thumbImage(item) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: selected ? 160 : 44, height: selected ? 160 : 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.vertical, selected ? 8 : 0)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(selected ? Color.white : IadenteTheme.ocean)
            }
        case .text, .file:
            kindIcon(item)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(selected ? Color.white : IadenteTheme.ocean)
        }
    }

    private func thumbImage(_ item: ClipboardItem) -> NSImage? {
        guard let data = item.imageData else { return nil }
        return NSImage(data: data)
    }

    @ViewBuilder
    private func kindIcon(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .text: Image(systemName: "text.alignleft")
        case .image: Image(systemName: "photo")
        case .file: Image(systemName: "doc")
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                ClipboardHistoryStore.shared.clear()
                state.selectedIndex = 0
            } label: {
                Label(IadenteL10n.t("清空历史", "Clear"), systemImage: "trash")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(IadenteL10n.t("清除全部剪贴板历史", "Clear all clipboard history"))

            Spacer(minLength: 0)

            Text(IadenteL10n.t("\(items.count) 条", "\(items.count) items"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(IadenteL10n.t("还没有记录。复制点什么试试。", "Nothing yet. Copy something to start."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// 某分类在「全部数据」中的条数（不受当前搜索词 / 分类过滤影响）。
    private func count(for cat: ClipboardCategory) -> Int {
        items.filter { cat.matches($0) }.count
    }

    private var noMatchState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: state.query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(state.query.isEmpty
                 ? IadenteL10n.t("该分类下还没有记录", "No items in this category")
                 : IadenteL10n.t("没有匹配的结果", "No matching results"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 小工具

private extension ClipboardItem {
    var timestampText: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt.string(from: timestamp)
    }

    // MARK: 文件元信息展示

    /// 友好文件类型名（中文）。无 UTI 时按扩展名回退。
    var fileTypeLabel: String {
        guard let uti = fileUTI, !uti.isEmpty else {
            return filePaths.first.flatMap { extLabel($0) }
                ?? IadenteL10n.t("文件", "File")
        }
        if uti == "public.directory" || uti == "public.folder" {
            return IadenteL10n.t("文件夹", "Folder")
        }
        let map: [String: String] = [
            "public.png": IadenteL10n.t("PNG 图像", "PNG Image"),
            "public.jpeg": IadenteL10n.t("JPEG 图像", "JPEG Image"),
            "public.jpeg-2000": IadenteL10n.t("JPEG 图像", "JPEG Image"),
            "public.tiff": IadenteL10n.t("TIFF 图像", "TIFF Image"),
            "public.heic": IadenteL10n.t("HEIC 图像", "HEIC Image"),
            "com.compuserve.gif": IadenteL10n.t("GIF 图像", "GIF Image"),
            "com.adobe.pdf": IadenteL10n.t("PDF 文档", "PDF Document"),
            "public.plain-text": IadenteL10n.t("文本文档", "Text Document"),
            "public.rtf": IadenteL10n.t("RTF 文档", "RTF Document"),
            "org.openxmlformats.wordprocessingml.document": IadenteL10n.t("Word 文档", "Word Document"),
            "com.microsoft.word.doc": IadenteL10n.t("Word 文档", "Word Document"),
            "org.openxmlformats.spreadsheetml.sheet": IadenteL10n.t("Excel 文档", "Excel Document"),
            "org.openxmlformats.presentationml.presentation": IadenteL10n.t("PPT 文档", "PPT Document"),
            "public.audio": IadenteL10n.t("音频文件", "Audio File"),
            "public.mp3": IadenteL10n.t("MP3 音频", "MP3 Audio"),
            "public.mpeg-4-audio": IadenteL10n.t("M4A 音频", "M4A Audio"),
            "public.movie": IadenteL10n.t("视频文件", "Video File"),
            "public.mpeg-4": IadenteL10n.t("MP4 视频", "MP4 Video"),
            "com.apple.quicktime-movie": IadenteL10n.t("MOV 视频", "MOV Video"),
            "public.zip-archive": IadenteL10n.t("ZIP 压缩包", "ZIP Archive"),
            "org.gnu.gnu-zip-archive": IadenteL10n.t("GZ 压缩包", "GZ Archive"),
            "public.tar-archive": IadenteL10n.t("TAR 压缩包", "TAR Archive"),
            "public.html": IadenteL10n.t("HTML 网页", "HTML Page"),
            "public.json": IadenteL10n.t("JSON 文件", "JSON File"),
            "public.xml": IadenteL10n.t("XML 文件", "XML File"),
            "public.source-code": IadenteL10n.t("源代码", "Source Code"),
            "com.apple.application": IadenteL10n.t("应用程序", "Application"),
            "com.apple.application-bundle": IadenteL10n.t("应用程序", "Application"),
            "public.executable": IadenteL10n.t("可执行文件", "Executable File"),
            "public.shell-script": IadenteL10n.t("脚本文件", "Script File"),
        ]
        if let label = map[uti] { return label }
        // 通用 image/data 等大类，回退到扩展名。
        if uti.hasPrefix("public.image") { return IadenteL10n.t("图片", "Image") }
        if uti.hasPrefix("public.audio") { return IadenteL10n.t("音频", "Audio") }
        if uti.hasPrefix("public.movie") || uti.hasPrefix("public.video") {
            return IadenteL10n.t("视频", "Video")
        }
        return extLabel(filePaths.first) ?? IadenteL10n.t("文件", "File")
    }

    /// 文件大小的可读文本（如 "2.4 MB"）。
    var fileSizeLabel: String {
        guard let size = fileSize, size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func extLabel(_ path: String?) -> String? {
        guard let path else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
        guard !ext.isEmpty else { return nil }
        return ext + IadenteL10n.t(" 文件", " File")
    }
}

// MARK: - 面板窗口

/// 剪贴板历史浮窗（键盘处理已迁移到控制器内的本地事件监听）。
final class ClipboardHistoryPanelWindow: NSWindow {}
