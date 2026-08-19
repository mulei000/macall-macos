import AppKit
import Foundation
import SwiftUI

// MARK: - 文字片段（常用语）

struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var body: String
    /// 是否置顶（参考剪贴板历史的「收藏」）。老 JSON 缺此字段时按 false 解码，避免清空用户数据。
    var pinned: Bool = false

    init(id: UUID = UUID(), title: String, body: String, pinned: Bool = false) {
        self.id = id; self.title = title; self.body = body; self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(pinned, forKey: .pinned)
    }
}

final class SnippetStore {
    static let shared = SnippetStore()
    private(set) var snippets: [Snippet] = []
    private let fileURL: URL

    private init() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/macall")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("snippets.json")
        load()
        if snippets.isEmpty {
            snippets = [
                Snippet(title: IadenteL10n.t("邮箱", "Email"), body: "you@example.com"),
                Snippet(title: IadenteL10n.t("地址", "Address"),
                        body: IadenteL10n.t("北京市朝阳区…", "No.1, Chaoyang, Beijing")),
            ]
            save()
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([Snippet].self, from: data) else { return }
        snippets = arr
    }

    func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ s: Snippet) { snippets.append(s); save() }
    func delete(_ s: Snippet) { snippets.removeAll { $0.id == s.id }; save() }
    func update(_ s: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s; save() }
    }

    /// 展示顺序：置顶项在前（保持原有相对顺序），其余在后。参考剪贴板历史的 displayItems。
    var displaySnippets: [Snippet] {
        snippets.sorted { $0.pinned && !$1.pinned }
    }

    func togglePin(_ s: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == s.id }) else { return }
        snippets[i].pinned.toggle()
        save()
    }

    func clear() {
        snippets.removeAll()
        save()
    }
}

// MARK: - 面板状态（Observable，承载搜索词与选中项，供键盘监听共享）

final class SnippetsPanelState: ObservableObject {
    @Published var query = ""
    @Published var selected = 0

    var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return SnippetStore.shared.displaySnippets }
        return SnippetStore.shared.displaySnippets.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let n = filtered.count
        selected = (selected + delta + n) % n
    }

    func current() -> Snippet? { filtered[safe: selected] }
}

// MARK: - 面板视图

/// 唤起面板。
///
/// v0.5.0 之前这里是一个 `.borderless + .nonactivatingPanel` 的 **NSWindow**，
/// 两个致命问题：① `.nonactivatingPanel` 对 NSWindow 无效，窗口拿不到 key 状态，
/// 搜索框敲不进字、行也点不动；② `backgroundColor = .clear` 但视图本身没有背景，
/// 于是整个面板半透明「看不清」。现在改成和剪贴板面板一样的路子：
/// 常规 NSWindow + 显式激活 + `IadenteWindowBackdrop` 背景，并在失去 key 时自动关闭。
private struct SnippetsView: View {
    @ObservedObject var state: SnippetsPanelState
    @Environment(\.colorScheme) private var colorScheme
    let onPick: (Snippet) -> Void
    let onManage: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(.primary.opacity(0.11))

            if state.filtered.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(state.filtered.enumerated()), id: \.element.id) { idx, s in
                                row(s, index: idx).id(s.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: state.selected) { _, _ in
                        if let cur = state.current() {
                            proxy.scrollTo(cur.id, anchor: .center)
                        }
                    }
                }
            }

            Divider().background(.primary.opacity(0.11))

            footer
        }
        .frame(width: 440, height: 540)
        .background(IadenteWindowBackdrop())
        .tint(IadenteTheme.ocean)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                IadenteIconBadge(
                    icon: "text.quote",
                    colors: [IadenteTheme.ocean, IadenteTheme.sky],
                    size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(IadenteL10n.t("文字片段", "Text Snippets"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(IadenteL10n.t("点击即粘贴 · ↑↓ 选择 · ↵ 粘贴 · esc 关闭",
                                       "Click to paste · ↑↓ select · ↵ paste · esc close"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(IadenteL10n.t("搜索片段", "Search snippets"), text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    private func row(_ s: Snippet, index: Int) -> some View {
        let selected = index == state.selected
        return Button {
            state.selected = index
            onPick(s)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title.isEmpty ? IadenteL10n.t("未命名", "Untitled") : s.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : .primary)
                    Text(s.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                // 置顶 ★：参考剪贴板历史每行的收藏按钮。
                Button {
                    SnippetStore.shared.togglePin(s)
                } label: {
                    let pinned = s.pinned
                    Image(systemName: pinned ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(pinned ? Color.yellow
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

    private var footer: some View {
        HStack(spacing: 14) {
            Button(action: onManage) {
                Label(IadenteL10n.t("管理片段", "Manage"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button(action: { SnippetStore.shared.clear(); state.selected = 0 }) {
                Label(IadenteL10n.t("清空", "Clear"), systemImage: "trash")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(IadenteL10n.t("清除全部文字片段", "Clear all text snippets"))

            Spacer()

            Text(IadenteL10n.t("\(state.filtered.count) 条", "\(state.filtered.count) items"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.quote")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(state.query.isEmpty
                 ? IadenteL10n.t("还没有片段。点「管理片段」新建一条。",
                                 "No snippets yet. Hit Manage to add one.")
                 : IadenteL10n.t("没有匹配的片段。", "No matching snippet."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private final class SnippetsPanelController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let state = SnippetsPanelState()
    private var onPick: ((Snippet) -> Void)?
    private var onClose: (() -> Void)?

    func show(onPick: @escaping (Snippet) -> Void, onClose: @escaping () -> Void) {
        self.onPick = onPick
        self.onClose = onClose
        state.query = ""
        state.selected = 0

        let view = SnippetsView(
            state: state,
            onPick: { [weak self] s in self?.pick(s) },
            onManage: { [weak self] in
                self?.close()
                DispatchQueue.main.async {
                    SnippetsManagerWindowController.shared.show()
                }
            },
            onClose: { [weak self] in self?.close() })

        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.appearance = Defaults[.appearanceMode].nsAppearance
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.cornerRadius = 14
        win.contentView?.layer?.masksToBounds = true
        win.setContentSize(NSSize(width: 440, height: 540))
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func pick(_ s: Snippet) {
        onPick?(s)
        close()
    }

    func move(_ delta: Int) { state.move(delta) }
    func commit() { if let s = state.current() { pick(s) } }

    func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        let cb = onClose
        onClose = nil
        cb?()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let cb = onClose
        onClose = nil
        cb?()
    }

    /// 点击窗口外部 / 切到别的 App 时失焦即关闭。
    /// 仅在 macall 真的失去活跃态时关闭，App 内瞬时失焦不误关。
    func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !NSApp.isActive else { return }
            self.close()
        }
    }
}

// MARK: - 功能

final class SnippetsFeature: Feature {
    let id = "snippets"
    var title: String { IadenteL10n.t("文字片段", "Text Snippets") }
    let category = FeatureCategory.other
    var enabledByDefault: Bool = true

    var isLaunchableTool: Bool { true }
    var launchAction: String? { "show" }

    private var context: AppContext?
    private var panel: SnippetsPanelController?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[snippets] 已安装：快捷键唤起文字片段面板，点击即粘贴")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["snippets.show"]?.toCombo()
            ?? Configuration.defaultHotkeys()["snippets.show"]!.toCombo()
        context?.hotkeys.bind(
            featureId: id, action: "show", configKey: "snippets.show", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "show" { togglePanel() }
    }

    func reload(config: Configuration) { bindHotkey(using: config) }
    func uninstall() { closePanel() }

    private func togglePanel() {
        if panel != nil { closePanel(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let p = SnippetsPanelController()
        p.show(
            onPick: { [weak self] s in self?.paste(s) },
            onClose: { [weak self] in self?.panel = nil; self?.removeKeyMonitor() })
        panel = p
        installKeyMonitor()
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        removeKeyMonitor()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            switch event.keyCode {
            case 126: self.panel?.move(-1); return nil
            case 125: self.panel?.move(1); return nil
            case 36, 76: self.panel?.commit(); return nil
            case 53: self.closePanel(); return nil
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func paste(_ s: Snippet) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s.body, forType: .string)
        if let app = previousApp {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.postCommandV() }
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = CGEventFlags.maskCommand
        up?.flags = CGEventFlags.maskCommand
        down?.post(tap: CGEventTapLocation.cghidEventTap)
        up?.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
