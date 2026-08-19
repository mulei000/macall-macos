import SwiftUI

/// 剪贴板设置页：剪贴板历史 + 剪贴板 OCR 两个模块，
/// 每个模块的总开关都在自己卡片的右上角（不再有集中的「功能」页）。
struct ClipboardSettingsView: View {
    @ObservedObject var model: SettingsModel

    /// 保留时长预设（天）。0 = 永久。
    private let retentionOptions: [(days: Int, label: String)] = [
        (0, IadenteL10n.t("永久", "Forever")),
        (1, IadenteL10n.t("1 天", "1 day")),
        (7, IadenteL10n.t("7 天", "7 days")),
        (30, IadenteL10n.t("30 天", "30 days")),
        (90, IadenteL10n.t("90 天", "90 days")),
    ]

    var body: some View {
        IadenteSettingsPage {
            FeatureModuleCard(model: model, featureID: "clipboard") {
                historyManagement
            }

            FeatureModuleCard(model: model, featureID: "clipboardocr")
        }
    }

    // MARK: - 历史管理

    @ViewBuilder
    private var historyManagement: some View {
        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("最多保留条数", "Maximum entries"),
            subtitle: IadenteL10n.t(
                "直接填写数字，范围 10 ~ 1000。超出后自动淘汰最旧的记录；置顶的条目不占用配额。",
                "Type a number between 10 and 1000. Oldest entries are dropped first; pinned items don't count."),
            icon: "tray.full",
            colors: IadenteTheme.automationColors
        ) {
            MaxItemsField(model: model)
        }

        IadenteRowDivider()

        IadenteControlRow(
            IadenteL10n.t("保留时长", "Retention"),
            subtitle: IadenteL10n.t(
                "超过该时长的记录会被自动清理；置顶条目永不过期。",
                "Entries older than this are purged; pinned items never expire."),
            icon: "clock.arrow.circlepath",
            colors: IadenteTheme.automationColors
        ) {
            Picker("", selection: Binding(
                get: { model.config.clipboardRetentionDays },
                set: {
                    model.config.clipboardRetentionDays = $0
                    model.save()
                }
            )) {
                ForEach(retentionOptions, id: \.days) { opt in
                    Text(opt.label).tag(opt.days)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }

        IadenteRowDivider()

        IadenteSettingToggle(
            IadenteL10n.t("记录图片", "Record images"),
            subtitle: IadenteL10n.t(
                "关闭后只记录文本与文件，历史文件会小很多。",
                "When off, only text and files are recorded."),
            icon: "photo",
            colors: IadenteTheme.automationColors,
            isOn: Binding(
                get: { model.config.clipboardKeepImages },
                set: {
                    model.config.clipboardKeepImages = $0
                    model.save()
                }
            )
        )

        IadenteRowDivider()

        IadenteSettingToggle(
            IadenteL10n.t("记录文件", "Record files"),
            subtitle: IadenteL10n.t(
                "关闭后在访达里拷贝文件 / 文件夹不会进入历史。",
                "When off, files and folders copied in Finder are not recorded."),
            icon: "doc",
            colors: IadenteTheme.automationColors,
            isOn: Binding(
                get: { model.config.clipboardKeepFiles },
                set: {
                    model.config.clipboardKeepFiles = $0
                    model.save()
                }
            )
        )

        IadenteRowDivider()

        ClipboardStorageRow()
    }
}

// MARK: - 条数输入框

/// 「最多保留条数」的数字输入。
///
/// 以前是 20…1000、步长 20 的滑块——想要 150 条根本拨不准，用户直接要求改成填数字。
/// 输入过程中不即时写配置（半截数字如 "1" 会把上限打到 10），
/// 只在回车 / 失焦时钳到 10…1000 再落盘。
private struct MaxItemsField: View {
    @ObservedObject var model: SettingsModel
    @State private var text: String = ""
    @FocusState private var focused: Bool

    private static let lower = 10
    private static let upper = 1000

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
            Text(IadenteL10n.t("条", "items"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .onAppear { text = String(model.config.clipboardMaxItems) }
        .onChange(of: model.config.clipboardMaxItems) { _, newValue in
            if !focused { text = String(newValue) }
        }
    }

    private func commit() {
        let digits = text.filter(\.isNumber)
        let value = Int(digits) ?? model.config.clipboardMaxItems
        let clamped = min(Self.upper, max(Self.lower, value))
        text = String(clamped)
        guard clamped != model.config.clipboardMaxItems else { return }
        model.config.clipboardMaxItems = clamped
        model.save()
    }
}

// MARK: - 当前占用 + 清空

/// 展示历史条数 / 磁盘占用，并提供「立即清理过期」「清空全部」。
private struct ClipboardStorageRow: View {
    @State private var confirmClear = false
    @State private var refreshToken = 0

    private var store: ClipboardHistoryStore { ClipboardHistoryStore.shared }

    private var summary: String {
        let count = store.items.count
        let pinned = store.pinnedIDs.count
        let mb = Double(store.storageBytes) / 1_048_576
        let size = mb >= 0.1
            ? String(format: "%.1f MB", mb)
            : String(format: "%.0f KB", Double(store.storageBytes) / 1024)
        return IadenteL10n.t(
            "当前 \(count) 条（置顶 \(pinned) 条），占用 \(size)",
            "\(count) entries (\(pinned) pinned), \(size) on disk")
    }

    var body: some View {
        IadenteControlRow(
            IadenteL10n.t("当前占用", "Current usage"),
            subtitle: summary,
            icon: "internaldrive",
            colors: IadenteTheme.automationColors
        ) {
            HStack(spacing: 8) {
                // 管理入口：多选 / 全选 / 反选 / 批量置顶 / 批量删除都在独立窗口里，
                // 塞进设置卡片会把页面撑爆（历史动辄上百条）。
                Button(IadenteL10n.t("管理…", "Manage…")) {
                    ClipboardManagerWindowController.shared.show {
                        refreshToken += 1
                    }
                }
                .controlSize(.small)
                .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.automationColors))

                Button(IadenteL10n.t("清理过期", "Purge")) {
                    store.purgeExpired()
                    refreshToken += 1
                }
                .controlSize(.small)

                Button(IadenteL10n.t("清空全部", "Clear all")) {
                    confirmClear = true
                }
                .controlSize(.small)
                .buttonStyle(IadenteActionButtonStyle(colors: [IadenteTheme.coral, IadenteTheme.amber]))
            }
        }
        .id(refreshToken)
        .alert(IadenteL10n.t("清空剪贴板历史？", "Clear clipboard history?"), isPresented: $confirmClear) {
            Button(IadenteL10n.t("取消", "Cancel"), role: .cancel) {}
            Button(IadenteL10n.t("清空", "Clear"), role: .destructive) {
                store.clear()
                refreshToken += 1
            }
        } message: {
            Text(IadenteL10n.t(
                "所有记录（含置顶）都会被删除，无法撤销。",
                "All entries including pinned ones will be deleted. This cannot be undone."))
        }
    }
}
