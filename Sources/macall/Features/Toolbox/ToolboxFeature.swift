import AppKit
import SwiftUI
import Combine

// MARK: - 工具箱（常驻状态栏图标）+ 工具启动面板
//
// 与系统监控、音量图标完全解耦：拥有自己的 NSStatusItem（工具箱符号），不在任何现有
// 状态栏聚合里。显隐由 Defaults[.showToolboxIcon] 单独控制，默认常驻。
//
// 点击弹出列表面板（宽 320，与音量弹窗统一），列出所有「可启动工具」
// （屏幕放大镜 / 屏幕取色 / 文字片段 / 二维码 / 键盘清洁），点击即调对应功能的
// `handle(action:)` 启动之。面板内容（顺序 + 显隐）由「工具箱」设置卡片管理，
// 由 Defaults[.toolboxOrder] / [.toolboxHidden] 驱动 —— 只管面板里摆什么，
// 不动各功能自己的总开关。
//
// 弹窗 UI 复用 IadenteWindowBackdrop + IadenteCard 设计语言；底层用无边框 non-activating
// NSPanel 自己定位（参考 VolumeStatusBarManager），顶边贴菜单栏下沿。

final class ToolboxFeature: Feature {
    let id = "toolbox"
    let title = IadenteL10n.t("工具箱", "Toolbox")
    let category = FeatureCategory.other
    var enabledByDefault: Bool = true

    /// 面板底部「打开工具箱设置」的回调，由 AppDelegate 注入（跳到 Tools 设置页）。
    var onOpenSettings: (() -> Void)?

    private var context: AppContext?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private var panel: ToolboxPanel?
    private var hosting: NSHostingController<ToolboxPanelContent>?
    private var dismissMonitors: [Any] = []

    private static let panelGap: CGFloat = 0
    private static let screenMargin: CGFloat = 4
    private static let panelWidth: CGFloat = 320

    func install(context: AppContext) {
        self.context = context
        ToolboxFeature.activeInstance = self
        migrateToolboxOrder()
        rebuildItem()
        observeState()
        startAppearanceObservation()
        Log.info("[toolbox] 已安装：常驻工具箱图标（点击弹出工具面板）")
    }

    /// 老用户升级后，其已保存的 `toolboxOrder` 里不含新加的工具 case，
    /// 会导致新工具既不出现在面板也不出现在设置排序列表。这里把 `allCases`
    /// 中存在、但旧数组里没有的项补到末尾，保留用户已有的顺序与显隐。
    private func migrateToolboxOrder() {
        var order = Defaults[.toolboxOrder]
        let known = Set(order)
        let missing = ToolboxTool.allCases.filter { !known.contains($0) }
        guard !missing.isEmpty else { return }
        order.append(contentsOf: missing)
        Defaults[.toolboxOrder] = order
        Log.info("[toolbox] 迁移 toolboxOrder：追加 \(missing.map { $0.rawValue })")
    }

    func uninstall() { removeItem() }
    func reload(config: Configuration) {}
    func handle(action: String) {}
    func ensureTap() {}
    func reenable() {}

    // MARK: - 图标

    private static let iconSymbolName = "toolbox.fill"
    private static let iconFallbackSymbolName = "square.grid.2x2.fill"
    private static let iconPointSize: CGFloat = 15

    /// 直接用 SF Symbol 模板图（与 KeyboardClean 临时图标同一写法）。
    /// 不自己画 canvas —— 自定义 canvas 绘制在模板化时容易失败，导致状态栏空白。
    /// symbol 在当前系统不存在时回落到 `square.grid.2x2.fill`。
    private func resolvedIcon() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .regular)
        let name = NSImage(systemSymbolName: Self.iconSymbolName, accessibilityDescription: nil) != nil
            ? Self.iconSymbolName
            : Self.iconFallbackSymbolName
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true
        return img
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let img = resolvedIcon()
        img?.accessibilityDescription = IadenteL10n.t("工具箱", "Toolbox")
        button.image = img
        button.imagePosition = .imageOnly
        // 钉死宽度：与系统菜单栏图标常用宽度接近（约 26pt），符号实际宽度 + 少量留白，
        // 避免过窄（空白）或过宽（与相邻图标间距过大、像一组联动的图标）。
        if let w = img?.size.width {
            statusItem?.length = max(24, ceil(w) + 6)
        } else {
            statusItem?.length = 26
        }
        button.toolTip = IadenteL10n.t("工具箱：点开使用小工具", "Toolbox: click to use tools")
    }

    // MARK: - 显隐

    private func rebuildItem() {
        if Defaults[.showToolboxIcon] {
            if let item = statusItem, let button = item.button {
                updateIcon()
                return
            }
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
            guard let item = statusItem, let button = item.button else {
                scheduleToolboxRetry()
                return
            }
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateIcon()
            toolboxSetupRetries = 0
        } else {
            removeItem()
        }
    }

    private func removeItem() {
        toolboxSetupRetries = 0
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        ToolboxFeature.activeInstance = nil
        closePanel()
    }

    /// button 早期为 nil 时延迟重试，避免工具箱图标静默丢失 / 开关反应迟钝。
    /// （与音量状态栏图标 `scheduleVolumeRetry` 同思路：NSStatusItem.button 创建后未必立即可用。）
    private var toolboxSetupRetries = 0
    private func scheduleToolboxRetry() {
        toolboxSetupRetries += 1
        if toolboxSetupRetries < 60 {
            Log.warning("[toolbox] button 尚未就绪，重试 #\(toolboxSetupRetries)")
            DispatchQueue.main.async { [weak self] in
                self?.rebuildItem()
            }
        } else {
            Log.error("[toolbox] button 持续为 nil，工具箱状态项无法挂载")
        }
    }

    private func observeState() {
        Task { [weak self] in
            for await _ in Defaults.updates(.showToolboxIcon, initial: false) {
                DispatchQueue.main.async { self?.rebuildItem() }
            }
        }
    }

    private func startAppearanceObservation() {
        Task { [weak self] in
            for await _ in Defaults.updates(.appearanceMode, initial: false) {
                self?.panel?.appearance = Defaults[.appearanceMode].nsAppearance
            }
        }
    }

    // MARK: - 面板生命周期

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard statusItem != nil else { return }
        if isPanelVisible { closePanel() } else { showPanel() }
    }

    var isPanelVisible: Bool { panel?.isVisible == true }

    private func makeRootView() -> ToolboxPanelContent {
        ToolboxPanelContent(
            onLaunch: { [weak self] tool in
                self?.closePanel()
                self?.context?.hotkeys.registry?.dispatch(
                    featureId: tool.rawValue, action: tool.launchAction)
            },
            onOpenSettings: { [weak self] in
                self?.closePanel()
                self?.onOpenSettings?()
            },
            onHeightChange: { [weak self] h in
                self?.resizePanel(toHeight: h)
            }
        )
    }

    private func configurePanel() -> ToolboxPanel {
        if let panel, let hosting {
            hosting.rootView = makeRootView()
            return panel
        }
        let controller = NSHostingController(rootView: makeRootView())
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 14
        controller.view.layer?.masksToBounds = true

        let p = ToolboxPanel(contentViewController: controller)
        p.styleMask = [.borderless, .nonactivatingPanel]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.appearance = Defaults[.appearanceMode].nsAppearance

        panel = p
        hosting = controller
        return p
    }

    private func showPanel() {
        let p = configurePanel()
        let frame = panelFrame(height: desiredPanelHeight())
        p.setFrame(frame, display: false)
        p.orderFrontRegardless()
        p.setFrameOrigin(frame.origin)
        p.makeKey()
        installDismissMonitors()
        Log.info("[toolbox] 打开工具面板 @\(Int(frame.minX)),\(Int(frame.minY))")
    }

    func closePanel() {
        removeDismissMonitors()
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        Log.info("[toolbox] 关闭工具面板")
    }

    /// 工具箱面板高度随内容自适应：内容有多高就多高，只在超出屏幕（Dock 上缘）时才钳住上限。
    /// 内容变少（隐藏工具）时面板随之缩短，内容变多（新增工具）时随之长高。
    private func resizePanel(toHeight height: CGFloat) {
        guard let p = panel, p.isVisible else { return }
        let maxH = availableHeightBelowStatusBar()
        let clamped = min(max(height,
                              ToolboxPopoverMetrics.minContentHeight + ToolboxPopoverMetrics.footerHeight),
                          maxH)
        let frame = panelFrame(height: clamped)
        guard frame != p.frame else { return }
        p.setFrame(frame, display: true)
    }

    private func desiredPanelHeight() -> CGFloat {
        max(160, min(ToolboxPopoverMetrics.initialHeight, availableHeightBelowStatusBar()))
    }

    private func availableHeightBelowStatusBar() -> CGFloat {
        guard let anchor = statusButtonScreenFrame() else {
            let h = NSScreen.main?.visibleFrame.height ?? 900
            return max(200, h - 12)
        }
        let visible = anchor.screen.visibleFrame
        let top = min(anchor.frame.minY - Self.panelGap, visible.maxY)
        return max(200, top - visible.minY - Self.screenMargin)
    }

    private func panelFrame(height: CGFloat) -> NSRect {
        let width = Self.panelWidth
        guard let anchor = statusButtonScreenFrame() else {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(x: visible.midX - width / 2, y: visible.maxY - height, width: width, height: height)
        }
        let screenFrame = anchor.screen.frame
        let visible = anchor.screen.visibleFrame
        let top = min(anchor.frame.minY - Self.panelGap, visible.maxY)
        var x = anchor.frame.midX - width / 2
        let minX = screenFrame.minX + Self.screenMargin
        let maxX = screenFrame.maxX - width - Self.screenMargin
        if maxX >= minX { x = min(max(x, minX), maxX) }
        let maxHeight = max(160, top - visible.minY - Self.screenMargin)
        let h = min(height, maxHeight)
        return NSRect(x: x.rounded(), y: (top - h).rounded(), width: width, height: h.rounded())
    }

    private func statusButtonScreenFrame() -> (screen: NSScreen, frame: NSRect)? {
        guard let button = statusItem?.button, let win = button.window else { return nil }
        let frame = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = win.screen ?? NSScreen.main else { return nil }
        return (screen, frame)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { _ in
            MainActor.assumeIsolated { ToolboxFeature.activeInstance?.closePanel() }
        }) { dismissMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if event.window === self.statusItem?.button?.window { return event }
            self.closePanel()
            return event
        }) { dismissMonitors.append(local) }
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            self.closePanel()
            return nil
        }) { dismissMonitors.append(key) }
    }

    private func removeDismissMonitors() {
        for m in dismissMonitors { NSEvent.removeMonitor(m) }
        dismissMonitors.removeAll()
    }

    private static weak var activeInstance: ToolboxFeature?
}

// MARK: - 面板

private final class ToolboxPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum ToolboxPopoverMetrics {
    static let initialHeight: CGFloat = 360
    static let footerHeight: CGFloat = 40
    static let minContentHeight: CGFloat = 120
}

private struct ToolboxContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ToolboxPanelContent: View {
    let onLaunch: (ToolboxTool) -> Void
    let onOpenSettings: () -> Void
    /// 把「内容 + 底栏」实际总高度回传给面板容器，使其随内容自适应
    /// （参考系统监控 / 音量状态栏弹窗：高度按显示内容而定）。
    let onHeightChange: (CGFloat) -> Void

    @Default(.toolboxOrder) private var toolboxOrder
    @Default(.toolboxHidden) private var toolboxHidden
    @State private var contentHeight: CGFloat = ToolboxPopoverMetrics.initialHeight

    private var visibleTools: [ToolboxTool] {
        let hidden = Set(toolboxHidden)
        return toolboxOrder.filter { !hidden.contains($0) }
    }

    /// 内容区可用高度：屏幕可视高度扣掉底部栏与少量呼吸空间。
    /// 内容超过它才钉到上限并滚动，平时「有多高显示多高」。
    private var availableContentHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(160, visible - 48) - ToolboxPopoverMetrics.footerHeight
    }

    private var resolvedContentHeight: CGFloat {
        min(max(contentHeight, ToolboxPopoverMetrics.minContentHeight),
            availableContentHeight)
    }

    var body: some View {
        ZStack {
            IadenteWindowBackdrop()
            VStack(spacing: 0) {
                contentArea
                footerView
            }
        }
        .frame(width: 320,
               height: resolvedContentHeight + ToolboxPopoverMetrics.footerHeight)
        .onPreferenceChange(ToolboxContentHeightKey.self) { h in
            guard h > 1, abs(h - contentHeight) > 0.5 else { return }
            contentHeight = h
        }
        .onChange(of: resolvedContentHeight) { _, _ in
            reportHeight()
        }
        .onAppear {
            reportHeight()
            // 布局稳定后再核一次，避免首帧内容未就位导致面板偏低被裁。
            DispatchQueue.main.async { reportHeight() }
        }
    }

    private func reportHeight() {
        onHeightChange(resolvedContentHeight + ToolboxPopoverMetrics.footerHeight)
    }

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if visibleTools.isEmpty {
                    Text(IadenteL10n.t(
                        "没有可显示的工具。去「工具箱」设置里把工具加回来。",
                        "No tools to show. Re-enable them in Toolbox settings."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(Array(visibleTools.enumerated()), id: \.element) { index, tool in
                        toolRow(tool)
                        if index < visibleTools.count - 1 {
                            IadenteRowDivider().padding(.leading, 46)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ToolboxContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .scrollIndicators(.never)
        .frame(height: resolvedContentHeight)
    }

    private func toolRow(_ tool: ToolboxTool) -> some View {
        Button(action: { onLaunch(tool) }) {
            HStack(spacing: 12) {
                IadenteIconBadge(icon: tool.icon, colors: IadenteTheme.aboutColors, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)
                    Text(tool.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(tool.title)
    }

    private var footerView: some View {
        VStack(spacing: 0) {
            IadenteRowDivider()
            Button(action: onOpenSettings) {
                Label(IadenteL10n.t("工具箱设置", "Toolbox Settings"),
                      systemImage: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: ToolboxPopoverMetrics.footerHeight - 1)
            }
            .buttonStyle(.plain)
        }
        .frame(height: ToolboxPopoverMetrics.footerHeight)
    }
}
