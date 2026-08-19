import AppKit
import SwiftUI

/// 文字片段管理窗口。
///
/// 设计页里只放一个「管理…」按钮，真正的增删改都在这个独立窗口里完成——
/// 片段可能有几十条，全部平铺进设置卡片会把页面撑得很长（v0.5.0 之前就是这个毛病）。
/// 唤起面板的 footer 也指向这里，两个入口共用同一份 UI。
@MainActor
final class SnippetsManagerWindowController: NSObject, NSWindowDelegate {
    static let shared = SnippetsManagerWindowController()

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(onClose: (() -> Void)? = nil) {
        self.onClose = onClose

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SnippetsManagerView())
        let win = NSWindow(contentViewController: hosting)
        win.title = IadenteL10n.t("文字片段管理", "Snippet Manager")
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 560, height: 520))
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

private struct SnippetsManagerView: View {
    @Default(.appLanguage) private var appLanguage

    @State private var snippets: [Snippet] = SnippetStore.shared.snippets
    @State private var query = ""
    @State private var selection: UUID?
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var isNew = false

    private var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            editor
                .frame(minWidth: 280)
        }
        .frame(minWidth: 520, minHeight: 420)
        .tint(IadenteTheme.jade)
    }

    // MARK: 左：列表

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(IadenteL10n.t("搜索", "Search"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            List(selection: $selection) {
                ForEach(filtered) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title.isEmpty ? IadenteL10n.t("未命名", "Untitled") : s.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(s.body.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(s.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    beginNew()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(IadenteL10n.t("新建片段", "New snippet"))

                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil || isNew)
                .help(IadenteL10n.t("删除所选", "Delete selected"))

                Spacer()

                Text(IadenteL10n.t("\(snippets.count) 条", "\(snippets.count) items"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onChange(of: selection) { _, newValue in
            isNew = false
            guard let id = newValue, let s = snippets.first(where: { $0.id == id }) else { return }
            draftTitle = s.title
            draftBody = s.body
        }
    }

    // MARK: 右：编辑器

    @ViewBuilder
    private var editor: some View {
        if selection == nil && !isNew {
            VStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(IadenteL10n.t("从左侧选择一条片段，或点「+」新建。",
                                   "Pick a snippet on the left, or hit + to create one."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(IadenteL10n.t("名称", "Title"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(IadenteL10n.t("例如：工作邮箱", "e.g. Work email"), text: $draftTitle)
                    .textFieldStyle(.roundedBorder)

                Text(IadenteL10n.t("内容", "Content"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $draftBody)
                    .font(.system(size: 12.5))
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.18))
                    )

                HStack {
                    Spacer()
                    Button(IadenteL10n.t("保存", "Save")) { commit() }
                        .controlSize(.regular)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(IadenteTheme.jade)
                }
            }
            .padding(16)
        }
    }

    // MARK: 动作

    private func beginNew() {
        isNew = true
        selection = nil
        draftTitle = ""
        draftBody = ""
    }

    private func deleteSelected() {
        guard let id = selection, let s = snippets.first(where: { $0.id == id }) else { return }
        SnippetStore.shared.delete(s)
        snippets = SnippetStore.shared.snippets
        selection = nil
    }

    private func commit() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            let s = Snippet(
                title: title.isEmpty ? IadenteL10n.t("未命名", "Untitled") : title,
                body: draftBody)
            SnippetStore.shared.add(s)
            snippets = SnippetStore.shared.snippets
            isNew = false
            selection = s.id
        } else if let id = selection, var s = snippets.first(where: { $0.id == id }) {
            s.title = title.isEmpty ? IadenteL10n.t("未命名", "Untitled") : title
            s.body = draftBody
            SnippetStore.shared.update(s)
            snippets = SnippetStore.shared.snippets
        }
    }
}
