import AppKit
import Foundation
import SwiftUI

// MARK: - 快捷键速查（Hotkey Cheat Sheet）

/// ⌃⌥H（可自定义）：弹出一个浮层，按模块分组列出所有已启用的快捷键，方便随时查看。
/// 复用 ScenePickerPanel 的浮层面板模式（borderless + nonactivating + 失焦关闭）。
final class HotkeyCheatSheetFeature: Feature {
    let id = "hotkeycheatsheet"
    let title = IadenteL10n.t("快捷键速查", "Hotkey Cheat Sheet")
    let category = FeatureCategory.system
    var enabledByDefault: Bool = true

    private var context: AppContext?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[hotkeycheatsheet] 已安装：⌃⌥H 弹出快捷键速查")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["hotkeycheatsheet.show"]?.toCombo()
            ?? Configuration.defaultHotkeys()["hotkeycheatsheet.show"]?.toCombo()
        guard let combo = combo else {
            Log.warning("[hotkeycheatsheet] 默认快捷键表缺少 hotkeycheatsheet.show，跳过绑定")
            return
        }
        context?.hotkeys.bind(
            featureId: id, action: "show", configKey: "hotkeycheatsheet.show", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "show" { showCheatSheet() }
    }

    private func showCheatSheet() {
        guard let registry = context?.hotkeys.registry,
              let config = context?.config else { return }
        let groups = buildGroups(registry: registry, config: config)
        HotkeyCheatSheetController.shared.show(groups: groups)
    }

    /// 遍历所有已启用功能，按模块聚合其已启用的快捷键。
    private func buildGroups(registry: FeatureRegistry, config: Configuration) -> [HotkeyCheatSheetController.Group] {
        var result: [HotkeyCheatSheetController.Group] = []
        for feature in registry.all {
            guard registry.isEnabled(feature.id) else { continue }
            let meta = FeatureCatalog.meta(feature.id)
            guard !meta.hotkeyPrefixes.isEmpty else { continue }
            var entries: [HotkeyCheatSheetController.Entry] = []
            for prefix in meta.hotkeyPrefixes {
                for (key, spec) in config.hotkeys where key.hasPrefix(prefix) {
                    guard config.isHotkeyEnabled(key) else { continue }
                    entries.append(HotkeyCheatSheetController.Entry(
                        label: Configuration.label(for: key), combo: spec))
                }
            }
            if !entries.isEmpty {
                result.append(HotkeyCheatSheetController.Group(
                    moduleTitle: feature.title, icon: meta.icon, entries: entries))
            }
        }
        return result
    }

    func reload(config: Configuration) {
        bindHotkey(using: config)
    }

    func uninstall() {}
}

// MARK: - 浮层控制器

/// 浮层面板。borderless + nonactivating 默认 `canBecomeKey` 为 false，
/// 不重写就无法成为 key 窗口——这会导致 ESC 局部键盘监听与「失焦收起」全部失效
/// （正是此前两个问题的根因）。故像 ScenePickerPanel 那样显式重写。
final class HotkeyCheatSheetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HotkeyCheatSheetController {
    static let shared = HotkeyCheatSheetController()

    struct Entry {
        let label: String
        let combo: HotkeySpec
    }
    struct Group {
        let moduleTitle: String
        let icon: String
        let entries: [Entry]
    }

    private(set) var panel: NSPanel?
    private var hosting: NSHostingController<HotkeyCheatSheetView>?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// 打开浮层前处于前台的 App，关闭时把焦点还给它（避免抢焦点）。
    private var previousApp: NSRunningApplication?
    var groups: [Group] = []

    private init() {}

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        show()
    }

    func show(groups: [Group]) {
        self.groups = groups
        toggle()
    }

    private func show() {
        let view = HotkeyCheatSheetView(controller: self)
        let hosting = NSHostingController(rootView: view)
        let size = NSSize(width: 580, height: 620)
        hosting.view.frame = NSRect(origin: .zero, size: size)

        // 与 ScenePickerPanel 一致的浮层配方：borderless + nonactivating，
        // 点一下不会把 macall 整个激活到最前、抢走当前窗口焦点；失焦自动收起。
        let panel = HotkeyCheatSheetPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting.view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // 记下当前前台 App，关闭时还回焦点；随后激活 macall 让浮层拿到 key 窗口
        // （borderless 面板只有成为 key 后，ESC 监听与失焦收起才会生效）。
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.hosting = hosting
        installDismissHooks(panel)
        Log.info("[hotkeycheatsheet] 快捷键速查已弹出（\(groups.count) 个模块）")
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = visible.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func close() {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        if let prev = previousApp {
            prev.activate()
            previousApp = nil
        }
    }

    private func installDismissHooks(_ panel: NSPanel) {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main)
        { [weak self] _ in MainActor.assumeIsolated { self?.close() } }

        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            if event.keyCode == 53 { // esc
                MainActor.assumeIsolated { self.close() }
                return nil
            }
            return event
        }
        if let local { monitors.append(local) }
    }
}

// MARK: - 浮层视图

struct HotkeyCheatSheetView: View {
    var controller: HotkeyCheatSheetController

    private var groups: [HotkeyCheatSheetController.Group] { controller.groups }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if groups.isEmpty {
                        Text(IadenteL10n.t("没有可显示的快捷键。", "No hotkeys to show."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 20)
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            groupSection(group)
                        }
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 580, height: 620)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
            Text(IadenteL10n.t("快捷键速查", "Hotkey Cheat Sheet"))
                .font(.system(size: 14, weight: .bold))
            Spacer(minLength: 0)
            Text(IadenteL10n.t("esc 关闭", "esc to close"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func groupSection(_ group: HotkeyCheatSheetController.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.icon)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(group.moduleTitle)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.bottom, 2)
            ForEach(group.entries, id: \.label) { entry in
                HStack(spacing: 10) {
                    Text(entry.label)
                        .font(.system(size: 12))
                    Spacer(minLength: 8)
                    comboChip(entry.combo)
                }
            }
        }
    }

    private func comboChip(_ combo: HotkeySpec) -> some View {
        HStack(spacing: 3) {
            Text(modifierSymbols(combo.flags))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text(KeyNames.display(for: combo.keyCode))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(IadenteL10n.t(
                "在「通用 → 快捷键速查」里可改启动键；各功能板块内能改其专属快捷键。",
                "Change the trigger in General → Hotkey Cheat Sheet; per-feature keys inside each module."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
