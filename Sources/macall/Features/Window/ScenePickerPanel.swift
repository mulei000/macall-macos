import AppKit
import Observation
import SwiftUI

// MARK: - 场景布局选择器（⌃⌥P）

/// 一个浮层：呼出后左栏列出所有场景（临时在前、预设在后），右栏实时预览选中场景
/// 保存时的画面（桌面合成截图）。键盘或点击选中即还原；临时场景可 ⇧↵ 升级为预设、⌫ 删除。
///
/// 还原逻辑完全复用 `LayoutStore`（含缺失 App 的尽力启动），本文件只做「选择 / 预览」这一层。

/// 浮层面板。需要能成为 key 窗口才能接收键盘选择，但 `.nonactivatingPanel` 避免
/// 点一下就把 macall 整个激活到最前、抢走当前窗口焦点。
final class ScenePickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 选择器控制器（单例，主线程）。负责面板的创建 / 定位 / 键盘导航 / 关闭。
@Observable
final class ScenePickerController {
    static let shared = ScenePickerController()

    private(set) var panel: ScenePickerPanel?
    private var hosting: NSHostingController<ScenePickerView>?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// 打开选择器前处于前台的 App，关闭时把焦点还给它（避免抢焦点）。
    private var previousApp: NSRunningApplication?

    /// 当前高亮项。`ScenePickerView` 直接读它来画高亮，键盘导航改它。
    var selected = 0

    /// 合并展示列表：临时场景在前，预设在后。
    var scenes: [LayoutScene] { LayoutStore.shared.allScenes }

    static let leftWidth: CGFloat = 300
    static let previewWidth: CGFloat = 400
    static let width: CGFloat = leftWidth + previewWidth + 24
    static let rowHeight: CGFloat = 58
    static let footerHeight: CGFloat = 42
    /// 面板至少占这么多行高（场景少时也不至于太矮，预览区随之放大）。
    static let minRows = 8
    static let maxRows = 12

    private init() {}

    // MARK: - 显隐

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        show()
    }

    private func show() {
        selected = 0
        let view = ScenePickerView(controller: self)
        let hosting = NSHostingController(rootView: view)
        let h = panelHeight()
        hosting.view.frame = NSRect(x: 0, y: 0, width: Self.width, height: h)

        let panel = ScenePickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting.view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // 记下当前前台 App，关闭时还回焦点
        previousApp = NSWorkspace.shared.frontmostApplication
        // 让 macall 成为活跃 App，否则非激活面板拿不到 key window，键盘事件会被当前 App 吃掉
        NSApp.activate(ignoringOtherApps: true)
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.hosting = hosting
        installDismissHooks(panel)
        Log.info("[windowlayout] 场景选择器已弹出（\(scenes.count) 个场景）")
    }

    private func panelHeight() -> CGFloat {
        let rows = min(max(scenes.count, Self.minRows), Self.maxRows)
        return CGFloat(rows) * Self.rowHeight + Self.footerHeight
    }

    /// 屏幕正中（水平 + 垂直居中）。
    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = visible.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 关闭

    func close(restoreFocus: Bool = true) {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        if restoreFocus, let prev = previousApp {
            prev.activate()
            previousApp = nil
        }
    }

    /// 失焦（点了别处）就收起；避免覆盖层一直挂着。
    private func installDismissHooks(_ panel: ScenePickerPanel) {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main)
        { [weak self] _ in MainActor.assumeIsolated { self?.close() } }

        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            MainActor.assumeIsolated { self.handleKey(event) }
            return nil
        }
        if let local { monitors.append(local) }
    }

    // MARK: - 键盘导航（仅面板是 key 时生效）

    private func handleKey(_ event: NSEvent) {
        switch event.keyCode {
        case 126: // ↑
            selected = max(0, selected - 1)
        case 125: // ↓
            selected = min(max(scenes.count - 1, 0), selected + 1)
        case 36, 76: // ↩ / ⌤
            if event.modifierFlags.contains(.shift) {
                promoteSelected()
            } else {
                pickSelected()
            }
        case 51: // ⌫
            deleteSelected()
        case 53: // esc
            close()
        default:
            if let d = Int(event.characters ?? ""), (1...9).contains(d), d <= scenes.count {
                selected = d - 1
                pickSelected()
            }
        }
    }

    /// 还原选中的场景（临时或预设均可）。
    func pickSelected() {
        guard scenes.indices.contains(selected) else { return }
        let id = scenes[selected].id
        let name = scenes.first(where: { $0.id == id })?.name ?? ""
        close()
        LayoutStore.shared.restoreScene(id: id)
        Log.info("[windowlayout] 通过选择器还原场景「\(name)」")
    }

    /// 把选中的「临时场景」升级为预设：先关面板，再弹命名框。
    func promoteSelected() {
        guard scenes.indices.contains(selected) else { return }
        let scene = scenes[selected]
        guard scene.kind == .temporary else { return }
        let id = scene.id
        let defaultName = scene.name
        close(restoreFocus: false)
        promptName(default: defaultName) { name in
            guard let name, !name.isEmpty else {
                // 取消也要把焦点还回去
                if let prev = self.previousApp { prev.activate(); self.previousApp = nil }
                return
            }
            LayoutStore.shared.promoteToPreset(id: id, name: name)
            // 命名完成后把焦点还回原 App
            if let prev = self.previousApp { prev.activate(); self.previousApp = nil }
            Log.info("[windowlayout] 已将临时场景升级为预设")
        }
    }

    /// 删除选中的「临时场景」。
    func deleteSelected() {
        guard scenes.indices.contains(selected) else { return }
        let scene = scenes[selected]
        guard scene.kind == .temporary else { return }
        LayoutStore.shared.deleteTemporary(id: scene.id)
        if selected >= scenes.count { selected = max(0, scenes.count - 1) }
    }

    /// 弹一个带输入框的命名框（模态）。completion 在用户点「保存」时带回名字。
    private func promptName(default: String, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = IadenteL10n.t("保存为预设", "Save as Preset")
        alert.informativeText = IadenteL10n.t("为这个场景取个名字：", "Name this scene:")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = `default`
        field.placeholderString = IadenteL10n.t("场景名称", "Scene name")
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field
        alert.addButton(withTitle: IadenteL10n.t("保存", "Save"))
        alert.addButton(withTitle: IadenteL10n.t("取消", "Cancel"))
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            completion(field.stringValue)
        } else {
            completion(nil)
        }
    }
}

// MARK: - 视图

struct ScenePickerView: View {
    var controller: ScenePickerController

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                sceneList
                    .frame(width: ScenePickerController.leftWidth)
                Divider()
                preview
            }
            .frame(height: bodyHeight())
            Divider()
            footerHints
        }
        .frame(width: ScenePickerController.width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bodyHeight() -> CGFloat {
        let rows = min(max(controller.scenes.count, ScenePickerController.minRows), ScenePickerController.maxRows)
        return CGFloat(rows) * ScenePickerController.rowHeight
    }

    private var sceneList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(controller.scenes.enumerated()), id: \.1.id) { idx, scene in
                        if idx == 0 || controller.scenes[idx - 1].kind != scene.kind {
                            sectionHeader(scene.kind)
                        }
                        row(idx, scene)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: controller.selected) { _, _ in
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(controller.selected, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ kind: SceneKind) -> some View {
        HStack {
            Text(kind == .temporary
                  ? IadenteL10n.t("临时场景", "Temporary")
                  : IadenteL10n.t("预设场景", "Presets"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(height: 24)
    }

    private var preview: some View {
        let scene = controller.scenes.indices.contains(controller.selected)
            ? controller.scenes[controller.selected] : nil
        return Group {
            if let scene, !scene.windows.isEmpty {
                ScenePreview(scene: scene)
                    .padding(8)
            } else {
                placeholder(scene)
            }
        }
        .frame(width: ScenePickerController.previewWidth)
    }

    private func placeholder(_ scene: LayoutScene?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.5))
            if let scene {
                let apps = Array(Set(scene.windows.map { $0.appLabel })).prefix(6)
                if !apps.isEmpty {
                    Text(apps.joined(separator: "、"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
                Text("\(scene.windowCount) \(IadenteL10n.t("个窗口", "windows"))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                Text(IadenteL10n.t("暂无场景", "No scene"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ idx: Int, _ scene: LayoutScene) -> some View {
        HStack(spacing: 10) {
            kindIcon(scene)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if (1...9).contains(idx + 1) {
                        Text("\(idx + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(scene.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if scene.id == LayoutStore.shared.lastSavedSceneID {
                        Text(IadenteL10n.t("最近", "Latest"))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(IadenteTheme.jade))
                    }
                }
                Text(scene.appLabels.isEmpty
                    ? "\(scene.windowCount) \(IadenteL10n.t("个窗口", "windows"))"
                    : "\(scene.appLabels.count) \(IadenteL10n.t("个 App", "apps"))：\(scene.appSummary)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: ScenePickerController.leftWidth, height: ScenePickerController.rowHeight, alignment: .leading)
        .id(idx)
        .background(controller.selected == idx ? Color.accentColor.opacity(0.20) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { controller.selected = idx }
        .onTapGesture(count: 2) { controller.pickSelected() }
    }

    private func kindIcon(_ scene: LayoutScene) -> some View {
        let sys: String
        let color: Color
        if scene.kind == .preset {
            sys = scene.pinned ? "pin.fill" : "pin"
            color = scene.pinned ? IadenteTheme.amber : Color.secondary.opacity(0.5)
        } else {
            sys = "clock"
            color = IadenteTheme.ocean
        }
        return Image(systemName: sys)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 18)
            .foregroundStyle(color)
    }

    private var footerHints: some View {
        HStack(spacing: 10) {
            hint("↑↓", IadenteL10n.t("选择", "Move"))
            hint("↵", IadenteL10n.t("还原", "Restore"))
            hint("⇧↵", IadenteL10n.t("存预设", "To Preset"))
            hint("⌫", IadenteL10n.t("删临时", "Del Temp"))
            hint("1–9", IadenteL10n.t("直达", "Jump"))
            hint("esc", IadenteL10n.t("关闭", "Close"))
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: ScenePickerController.footerHeight)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            keyChip(key)
            Text(label)
        }
    }

    private func keyChip(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
    }
}

/// 场景的「窗口布局示意图」：按保存时各窗口的真实坐标与尺寸，等比缩放绘制到画布上。
/// 不依赖屏幕录制权限，也不使用被新版 SDK 标记为不可用的截图 API；
/// 直观表达「这套场景里窗口是怎么摆的」。
struct ScenePreview: View {
    let scene: LayoutScene

    private var bounds: CGRect {
        let rects = scene.windows.map { $0.frame }
        guard let first = rects.first else { return .zero }
        var minX = first.minX, minY = first.minY, maxX = first.maxX, maxY = first.maxY
        for r in rects {
            minX = min(minX, r.minX); minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY)
        }
        return CGRect(x: minX, y: minY,
                      width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    private func colorFor(_ i: Int) -> Color {
        let palette: [Color] = [
            IadenteTheme.ocean, IadenteTheme.jade, IadenteTheme.amber,
            Color(NSColor.systemPurple), Color(NSColor.systemTeal), Color(NSColor.systemPink),
        ]
        return palette[i % palette.count]
    }

    var body: some View {
        GeometryReader { geo in
            let b = bounds
            let pad: CGFloat = 0.92
            let scale = min(geo.size.width / b.width, geo.size.height / b.height) * pad
            let ox = (geo.size.width - b.width * scale) / 2
            let oy = (geo.size.height - b.height * scale) / 2
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                ForEach(Array(scene.windows.enumerated()), id: \.1.id) { i, w in
                    let rx = (w.frame.minX - b.minX) * scale + ox
                    let ry = (w.frame.minY - b.minY) * scale + oy
                    let rw = max(w.frame.width * scale, 6)
                    let rh = max(w.frame.height * scale, 6)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(colorFor(i).opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(colorFor(i), lineWidth: 1))
                        .frame(width: rw, height: rh)
                        .position(x: rx + rw / 2, y: ry + rh / 2)
                }
            }
        }
    }
}
