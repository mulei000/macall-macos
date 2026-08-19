import SwiftUI

/// 场景布局设置页：管理「预设场景」快照（新建/还原/重命名/删除/置顶），
/// 并提供手动「保存为临时场景 / 还原最近场景」、以及临时场景保留数量设置。
/// 窗口位置的读取与还原依赖辅助功能权限，故在顶部给出权限横幅。
/// 把配置里当前绑定的快捷键（或默认值）转成可读的 ⌃⌥X 形式。
private func configuredShortcutText(for key: String, model: SettingsModel) -> String {
    let spec = model.config.hotkeys[key] ?? Configuration.defaultHotkeys()[key]
    guard let spec = spec else { return "" }
    return hotkeyDisplayString(spec)
}

struct WindowLayoutSettingsView: View {
    @ObservedObject var model: SettingsModel
    @Default(.appLanguage) private var appLanguage

    @State private var showNewScene = false
    @State private var newSceneName = ""
    @State private var renameTarget: LayoutScene?
    @State private var renameName = ""
    @State private var promoteTarget: LayoutScene?
    @State private var promoteName = ""

    private var store: LayoutStore { LayoutStore.shared }

    /// 临时场景保留数量（3…12），夹紧后写回配置。
    private var maxTempBinding: Binding<Int> {
        Binding(
            get: { model.config.maxTemporaryScenes },
            set: { v in
                model.config.maxTemporaryScenes = max(3, min(12, v))
                model.save()
            })
    }

    var body: some View {
        IadenteSettingsPage {
            // 辅助功能权限横幅（与窗口页共用同一组件，样式一致）
            if !Permissions.isAccessibilityWorking() {
                AccessibilityPermissionBanner()
            }

            // 模块总开关 + 快捷键 + 手动保存/还原，全部收在同一张卡里。
            FeatureModuleCard(model: model, featureID: "windowlayout") {
                IadenteRowDivider()
                HStack(spacing: 12) {
                    Button {
                        store.saveToTemporary()
                    } label: {
                        Label(
                            IadenteL10n.t("保存为临时场景", "Save as Temporary"),
                            systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(IadenteTheme.jade)

                    Button {
                        store.restoreLastSaved()
                    } label: {
                        Label(
                            IadenteL10n.t("还原最近场景", "Restore Latest"),
                            systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)

                let saveSC = configuredShortcutText(for: "layout.save", model: model)
                let restoreSC = configuredShortcutText(for: "layout.restore", model: model)
                let pickerSC = configuredShortcutText(for: "layout.picker", model: model)
                Text(IadenteL10n.t(
                    "\(saveSC) 抓取当前窗口布局存为「临时场景」（退出软件后自动清除）；\(restoreSC) 还原最近一次保存；\(pickerSC) 打开选择器（左名右图，可升级为预设）。",
                    "\(saveSC) saves current windows as a temporary scene (cleared on quit); \(restoreSC) restores the latest; \(pickerSC) opens the picker."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }

            // 临时场景保留数量
            IadenteCard(
                IadenteL10n.t("临时场景保留数量", "Temporary Scene Limit"),
                subtitle: IadenteL10n.t(
                    "临时场景只在本次运行期间保留，最多保存这么多条，超出丢弃最旧的。软件退出后全部清除。",
                    "Temporary scenes live only for this session, up to this many; oldest is dropped when exceeded. Cleared on quit."
                ),
                icon: "clock",
                colors: IadenteTheme.dashboardColors
            ) {
                HStack(spacing: 12) {
                    Stepper(
                        value: maxTempBinding,
                        in: 3...12,
                        step: 1
                    ) {
                        Text(IadenteL10n.t("保留", "Keep"))
                    }
                    .controlSize(.small)
                    Text("\(model.config.maxTemporaryScenes)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }

            // 临时场景列表（设置页也可直接查看与管理 ⌃⌥S 创建的场景）
            let saveShortcut = configuredShortcutText(for: "layout.save", model: model)
            IadenteCard(
                IadenteL10n.t("临时场景", "Temporary Scenes"),
                subtitle: IadenteL10n.t(
                    "快捷键 \(saveShortcut) 保存的场景都在这里，本次运行期间保留（退出即清除）。可升级为预设长期保留、直接还原或删除。",
                    "Scenes saved via \(saveShortcut) appear here; kept for this session only (cleared on quit). Promote to a preset, restore, or delete."
                ),
                icon: "clock",
                colors: IadenteTheme.dashboardColors
            ) {
                VStack(spacing: 8) {
                    if store.temporaryScenes.isEmpty {
                        let shortcut = configuredShortcutText(for: "layout.save", model: model)
                        Text(IadenteL10n.t("暂无临时场景，按 \(shortcut) 保存当前窗口布局。",
                                           "No temporary scenes yet. Press \(shortcut) to save."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(store.temporaryScenes) { scene in
                            tempRow(scene)
                            if scene.id != store.temporaryScenes.last?.id {
                                IadenteRowDivider()
                            }
                        }
                    }
                }
            }

            // 预设场景列表
            IadenteCard(
                IadenteL10n.t("预设场景", "Preset Scenes"),
                subtitle: IadenteL10n.t(
                    "预设会持久保存（重启后仍在）。把临时场景升级为预设即可长期保留。",
                    "Presets persist across launches. Promote a temporary scene to keep it."
                ),
                icon: "square.stack.3d.up",
                colors: IadenteTheme.dashboardColors
            ) {
                VStack(spacing: 8) {
                    ForEach(store.orderedPresets()) { scene in
                        sceneRow(scene)
                        if scene.id != store.orderedPresets().last?.id {
                            IadenteRowDivider()
                        }
                    }

                    Button {
                        showNewScene = true
                    } label: {
                        Label(IadenteL10n.t("新建预设（抓取当前布局）", "New Preset (capture now)"),
                              systemImage: "plus.circle")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(IadenteTheme.ocean)
                    .padding(.top, 4)
                }
            }
        }
        .alert(IadenteL10n.t("新建预设", "New Preset"), isPresented: $showNewScene) {
            TextField(IadenteL10n.t("场景名称", "Scene name"), text: $newSceneName)
            Button(IadenteL10n.t("取消", "Cancel"), role: .cancel) { newSceneName = "" }
            Button(IadenteL10n.t("创建", "Create")) {
                store.addPreset(name: newSceneName)
                newSceneName = ""
            }
        }
        .alert(IadenteL10n.t("重命名场景", "Rename Scene"), isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField(IadenteL10n.t("场景名称", "Scene name"), text: $renameName)
            Button(IadenteL10n.t("取消", "Cancel"), role: .cancel) { renameTarget = nil }
            Button(IadenteL10n.t("完成", "Done")) {
                if let target = renameTarget {
                    store.renameScene(id: target.id, name: renameName)
                }
                renameTarget = nil
            }
        }
        .alert(IadenteL10n.t("保存为预设", "Save as Preset"), isPresented: Binding(
            get: { promoteTarget != nil },
            set: { if !$0 { promoteTarget = nil } }
        )) {
            TextField(IadenteL10n.t("场景名称", "Scene name"), text: $promoteName)
            Button(IadenteL10n.t("取消", "Cancel"), role: .cancel) { promoteTarget = nil }
            Button(IadenteL10n.t("保存", "Save")) {
                if let target = promoteTarget {
                    store.promoteToPreset(id: target.id, name: promoteName)
                }
                promoteTarget = nil
            }
        }
    }

    // MARK: - 场景行

    private func sceneRow(_ scene: LayoutScene) -> some View {
        let isLatest = scene.id == store.lastSavedSceneID
        return HStack(spacing: 10) {
            // 置顶开关：图钉实心 = 已置顶。置顶的场景恒排在列表最前。
            Button {
                store.togglePinned(id: scene.id)
            } label: {
                Image(systemName: scene.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(scene.pinned ? IadenteTheme.amber : Color.secondary.opacity(0.5))
            .help(scene.pinned
                  ? IadenteL10n.t("取消置顶", "Unpin")
                  : IadenteL10n.t("置顶此场景", "Pin to top"))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(scene.name)
                        .font(.system(size: 13, weight: isLatest ? .semibold : .regular))
                    if isLatest {
                        Text(IadenteL10n.t("最近", "Latest"))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background {
                                Capsule().fill(IadenteTheme.jade)
                            }
                    }
                }
                Text(Self.metaText(scene))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            smallButton(IadenteL10n.t("还原", "Restore"),
                        icon: "arrow.clockwise") { store.restoreScene(id: scene.id) }
            smallButton(IadenteL10n.t("重命名", "Rename"),
                        icon: "pencil") {
                renameTarget = scene
                renameName = scene.name
            }
            smallButton(IadenteL10n.t("删除", "Delete"),
                        icon: "trash", destructive: true) { store.deletePreset(id: scene.id) }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 临时场景行（可升级 / 还原 / 删除）

    private func tempRow(_ scene: LayoutScene) -> some View {
        let isLatest = scene.id == store.lastSavedSceneID
        return HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(IadenteTheme.ocean)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(scene.name)
                        .font(.system(size: 13, weight: isLatest ? .semibold : .regular))
                    if isLatest {
                        Text(IadenteL10n.t("最近", "Latest"))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background { Capsule().fill(IadenteTheme.jade) }
                    }
                }
                Text(Self.metaText(scene))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            smallButton(IadenteL10n.t("存预设", "To Preset"), icon: "star") {
                promoteTarget = scene
                promoteName = scene.name
            }
            smallButton(IadenteL10n.t("还原", "Restore"), icon: "arrow.clockwise") {
                store.restoreScene(id: scene.id)
            }
            smallButton(IadenteL10n.t("删除", "Delete"), icon: "trash", destructive: true) {
                store.deleteTemporary(id: scene.id)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 场景元信息文案（哪几个 App · 几个窗口 · 更新时间）

    private static func metaText(_ scene: LayoutScene) -> String {
        var parts: [String] = []
        if !scene.appSummary.isEmpty { parts.append(scene.appSummary) }
        parts.append("\(scene.windowCount) \(IadenteL10n.t("窗口", "windows"))")
        parts.append(updatedText(scene.updatedAt))
        return parts.joined(separator: " · ")
    }

    private func smallButton(_ title: String, icon: String, destructive: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red : Color.secondary)
    }

    // MARK: - 时间格式

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func updatedText(_ date: Date) -> String {
        IadenteL10n.t("更新于 ", "Updated ") + dateFmt.string(from: date)
    }
}
