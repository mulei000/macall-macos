import AppKit
import SwiftUI

/// 剪贴板历史管理窗口。
///
/// 与「唤起面板」的分工：面板是**用**历史（点一下就粘贴，键盘操作，用完即走），
/// 这里是**管**历史（多选、批量置顶、批量删除）。两件事塞进同一个面板会互相打架：
/// 面板里点条目要立刻粘贴，管理器里点条目应该是勾选。所以拆成两个窗口。
@MainActor
final class ClipboardManagerWindowController: NSObject, NSWindowDelegate {
    static let shared = ClipboardManagerWindowController()

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(onClose: (() -> Void)? = nil) {
        self.onClose = onClose

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: ClipboardManagerView())
        let win = NSWindow(contentViewController: hosting)
        win.title = IadenteL10n.t("剪贴板历史管理", "Clipboard Manager")
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 620, height: 560))
        win.center()
        win.isReleasedWhenClosed = false
        win.appearance = Defaults[.appearanceMode].nsAppearance
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
            onClose?()
            onClose = nil
        }
    }
}

// MARK: - 管理界面

private struct ClipboardManagerView: View {
    @Default(.appLanguage) private var appLanguage
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var checked: Set<UUID> = []
    @State private var confirmDelete = false
    /// 每次改动 store 后 +1，强制视图重算（store 是 @Observable，
    /// 但这里读的是它的计算属性，显式打点更稳）。
    @State private var revision = 0

    private var store: ClipboardHistoryStore { ClipboardHistoryStore.shared }

    private var rows: [ClipboardItem] {
        let all = store.displayItems
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.previewText.localizedCaseInsensitiveContains(q)
                || $0.detailText.localizedCaseInsensitiveContains(q)
                || $0.appName.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 560, minHeight: 420)
        .tint(IadenteTheme.jade)
        .alert(IadenteL10n.t("删除所选条目？", "Delete selected entries?"),
               isPresented: $confirmDelete) {
            Button(IadenteL10n.t("取消", "Cancel"), role: .cancel) {}
            Button(IadenteL10n.t("删除", "Delete"), role: .destructive) {
                store.delete(ids: checked)
                checked.removeAll()
                revision += 1
            }
        } message: {
            Text(IadenteL10n.t("将删除 \(checked.count) 条记录，无法撤销。",
                               "\(checked.count) entries will be removed. This cannot be undone."))
        }
    }

    // MARK: 顶部：搜索 + 全选 / 反选

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(IadenteL10n.t("搜索内容 / 来源 App", "Search content or source app"),
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.05)))

            Spacer(minLength: 0)

            // 「全选」只作用于当前筛选出来的行 —— 搜索了关键字还去全选整库，
            // 是最容易误删的交互。
            Button(IadenteL10n.t("全选", "Select All")) {
                checked.formUnion(rows.map(\.id))
            }
            .controlSize(.small)

            Button(IadenteL10n.t("反选", "Invert")) {
                let visible = Set(rows.map(\.id))
                checked = visible.subtracting(checked).union(checked.subtracting(visible))
            }
            .controlSize(.small)

            Button(IadenteL10n.t("取消选择", "Clear")) { checked.removeAll() }
                .controlSize(.small)
                .disabled(checked.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(rows) { item in
                    row(item)
                }
            }
            .padding(12)
        }
        .id(revision)
    }

    private func row(_ item: ClipboardItem) -> some View {
        let isChecked = checked.contains(item.id)
        let pinned = store.isPinned(id: item.id)
        return HStack(spacing: 10) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(isChecked ? IadenteTheme.jade : Color.secondary.opacity(0.6))
                .frame(width: 20)

            kindIcon(item)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(IadenteTheme.ocean)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.previewText.isEmpty ? item.detailText : item.previewText)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.timeText(item.timestamp))
                    if !item.appName.isEmpty { Text("· \(item.appName)") }
                    if pinned {
                        Text(IadenteL10n.t("· 已置顶", "· pinned"))
                            .foregroundStyle(IadenteTheme.amber)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                store.setPinned(id: item.id, !pinned)
                revision += 1
            } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(pinned ? Color.yellow : Color.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(IadenteL10n.t("置顶 / 取消置顶", "Pin / unpin"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isChecked
                      ? IadenteTheme.jade.opacity(0.16)
                      : Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.035)))
        .contentShape(Rectangle())
        .onTapGesture {
            if isChecked { checked.remove(item.id) } else { checked.insert(item.id) }
        }
    }

    @ViewBuilder
    private func kindIcon(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .text: Image(systemName: "text.alignleft")
        case .image: Image(systemName: "photo")
        case .file: Image(systemName: "doc")
        }
    }

    // MARK: 底部：批量动作

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(IadenteL10n.t("已选 \(checked.count) / \(rows.count) 条",
                               "\(checked.count) of \(rows.count) selected"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                store.setPinned(ids: orderedChecked, true)
                revision += 1
            } label: {
                Label(IadenteL10n.t("置顶所选", "Pin"), systemImage: "star.fill")
                    .font(.system(size: 11.5))
            }
            .controlSize(.small)
            .disabled(checked.isEmpty)

            Button {
                store.setPinned(ids: orderedChecked, false)
                revision += 1
            } label: {
                Label(IadenteL10n.t("退出置顶", "Unpin"), systemImage: "star.slash")
                    .font(.system(size: 11.5))
            }
            .controlSize(.small)
            .disabled(checked.isEmpty)

            Button {
                confirmDelete = true
            } label: {
                Label(IadenteL10n.t("删除所选", "Delete"), systemImage: "trash")
                    .font(.system(size: 11.5))
            }
            .controlSize(.small)
            .disabled(checked.isEmpty)
            .buttonStyle(IadenteActionButtonStyle(colors: [IadenteTheme.coral, IadenteTheme.amber]))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// 批量置顶要按**当前列表从下往上**的顺序执行：
    /// `setPinned` 每次把新置顶的插到最前，倒着来才能让列表里靠上的那条最终仍在上面。
    private var orderedChecked: [UUID] {
        rows.map(\.id).filter { checked.contains($0) }.reversed()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty
                 ? IadenteL10n.t("还没有记录。", "Nothing recorded yet.")
                 : IadenteL10n.t("没有匹配的记录。", "No matching entries."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}
