import AppKit
import SwiftUI
import Combine
import CoreAudio

// MARK: - 独立音量菜单栏图标（喇叭形）+ 管理弹窗
//
// 与系统监控模块完全解耦：它拥有自己的 NSStatusItem，不在主 macall 状态栏聚合里。
// - 图标随系统音量 / 静音实时变化（speaker.wave.1/2/3.fill ↔ speaker.slash.fill）。
// - 点击弹出管理弹窗：主音量滑杆、静音、输出设备快速切换，以及逐 App 音量控制。
// - 显隐由 Defaults[.showVolumeStatusBarIcon] 单独控制，不依赖系统监控开关。
//
// 弹窗 UI 与「系统监控」状态栏弹窗统一：IadenteWindowBackdrop 玻璃背景 +
// IadenteCard / IadenteSectionHeader 设计语言。宽度 320（与系统监控弹窗一致）。
// 结构（无顶栏）：四个可配置模块，顺序与是否显示由「弹窗模块」设置管理
//   · 「主音量」模块（常驻，不可隐藏）：当前输出/输入设备胶囊 + 滑杆 + 静音/麦克风图标
//   · 可折叠「输入设备」模块：麦克风静音总开关 + 系统默认输入设备单选
//   · 可折叠「输出设备切换」模块：单选系统默认输出（含「跟随系统」）
//   · 可折叠「App 音量」模块（全部活跃 App，可隐藏 + 已隐藏找回）
//   + 固定底部栏。高度随内容自适应（不出现下拉条），超出屏幕才钉住上限并允许滚动。

extension NSNotification.Name {
    /// 系统默认输入/输出设备变化时广播，音量弹窗据此刷新设备显示。
    static let volumeDefaultDeviceChanged = NSNotification.Name("macall.volumeDefaultDeviceChanged")
    /// 默认输入设备静音状态变化时广播，音量弹窗据此刷新麦克风图标。
    static let volumeInputMuteChanged = NSNotification.Name("macall.volumeInputMuteChanged")
}

@MainActor
final class VolumeStatusBarManager: NSObject {
    private var statusItem: NSStatusItem?
    private let settingsWindowController: SettingsWindowController
    private let settingsModel: SettingsModel
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 自定义面板（与系统监控弹窗一致）
    //
    // NSPopover 会强制在状态栏按钮和弹窗之间保留一段系统默认间距，且水平位置不由我们控制，
    // 无法做到「贴边」。改用无边框 NSPanel 自己定位，顶边直接压在菜单栏下沿。
    private var panel: VolumePanel?
    private var hosting: NSHostingController<VolumeControlPopover>?
    private var dismissMonitors: [Any] = []

    /// 面板顶边与菜单栏下沿之间的缝隙；0 表示完全贴边，与系统监控弹窗的 4pt 缝隙区分。
    private static let panelGap: CGFloat = 0
    /// 面板离屏幕左右 / 底部（Dock 上缘）的最小留白。
    private static let screenMargin: CGFloat = 4

    init(settingsWindowController: SettingsWindowController, settingsModel: SettingsModel) {
        self.settingsWindowController = settingsWindowController
        self.settingsModel = settingsModel
        super.init()
        Self.activeInstance = self
        rebuildItem()
        observeState()
        startAppearanceObservation()
    }

    private func makeRootView() -> VolumeControlPopover {
        VolumeControlPopover(
            model: settingsModel,
            onOpenSettings: { [weak self] in
                self?.closePanel()
                self?.settingsWindowController.showSettings(tab: .audio)
            },
            onHeightChange: { [weak self] height in
                // 高度在 SwiftUI 更新过程中回传，异步派发避免「视图更新中改状态」告警。
                DispatchQueue.main.async { self?.resizePanel(toHeight: height) }
            }
        )
    }

    private func configurePanel() -> VolumePanel {
        if let panel, let hosting {
            hosting.rootView = makeRootView()
            return panel
        }

        let controller = NSHostingController(rootView: makeRootView())
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 14
        controller.view.layer?.masksToBounds = true

        let p = VolumePanel(contentViewController: controller)
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

    /// 弹窗内容高度自适应：内容有多长就多高，只在超出屏幕时被上限钳住。
    /// 尺寸改变时通过 `panelFrame` 重新摆位，确保顶边始终贴住菜单栏下沿。
    private func resizePanel(toHeight height: CGFloat) {
        guard let p = panel, p.isVisible else { return }
        let maxH = availableHeightBelowStatusBar()
        let clamped = min(max(height, VolumePopoverMetrics.minContentHeight), maxH)
        let frame = panelFrame(height: clamped)
        guard frame != p.frame else { return }
        p.setFrame(frame, display: true)
    }

    /// 按开关重建 / 移除状态栏图标。
    private func rebuildItem() {
        if Defaults[.showVolumeStatusBarIcon] {
            // 已建且按钮就绪：仅刷新图标。
            if let item = statusItem, let button = item.button {
                updateIcon()
                return
            }
            // 未建则先建；建了但 button 还没就绪则等下一轮重试。
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
            guard let item = statusItem, let button = item.button else {
                scheduleVolumeRetry()
                return
            }
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateIcon()
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    /// button 早期为 nil 时延迟重试，避免音量图标静默丢失。
    private var volumeSetupRetries = 0
    private func scheduleVolumeRetry() {
        volumeSetupRetries += 1
        if volumeSetupRetries < 60 {
            Log.warning("[volume-statusbar] button 尚未就绪，重试 #\(volumeSetupRetries)")
            DispatchQueue.main.async { [weak self] in
                self?.rebuildItem()
            }
        } else {
            Log.error("[volume-statusbar] button 持续为 nil，音量状态项无法挂载")
        }
    }

    /// 状态栏图标可能用到的全部符号。宽度各不相同（speaker.wave.3.fill 最宽、
    /// speaker.fill 最窄），若直接交给 variableLength 的 NSStatusItem，
    /// 切换静音时菜单栏项会突然变窄/变宽，导致图标左右「弹跳」。
    private static let iconSymbolNames = [
        "speaker.fill",
        "speaker.slash.fill",
        "speaker.wave.1.fill",
        "speaker.wave.2.fill",
        "speaker.wave.3.fill",
    ]

    private static let iconPointSize: CGFloat = 14

    /// 所有候选符号里最大的外接尺寸 —— 统一画布，保证任何状态下宽度恒定。
    private static let iconCanvasSize: NSSize = {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular)
        var w: CGFloat = 0
        var h: CGFloat = 0
        for name in iconSymbolNames {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { continue }
            w = max(w, img.size.width)
            h = max(h, img.size.height)
        }
        // 兜底 + 两侧各留 1pt，避免最宽符号贴边被裁。
        return NSSize(width: ceil(max(w, 18)) + 2, height: ceil(max(h, 14)))
    }()

    /// 把符号居中绘制到固定画布上，输出宽高恒定的模板图。
    private static func fixedWidthIcon(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }

        let canvas = iconCanvasSize
        let image = NSImage(size: canvas)
        image.lockFocus()
        let s = symbol.size
        let rect = NSRect(
            x: ((canvas.width - s.width) / 2).rounded(),
            y: ((canvas.height - s.height) / 2).rounded(),
            width: s.width,
            height: s.height
        )
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// 用当前系统音量 / 静音状态挑选合适的喇叭图标。模板图随菜单栏外观自动反色。
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let sys = SystemVolumeObserver.shared
        let name: String
        if sys.muted {
            name = "speaker.slash.fill"
        } else if sys.volume <= 0 {
            name = "speaker.fill"
        } else if sys.volume < 0.34 {
            name = "speaker.wave.1.fill"
        } else if sys.volume < 0.67 {
            name = "speaker.wave.2.fill"
        } else {
            name = "speaker.wave.3.fill"
        }
        let img = Self.fixedWidthIcon(name)
        img?.accessibilityDescription = IadenteL10n.t("音量", "Volume")
        button.image = img
        button.imagePosition = .imageOnly
        // 再钉死状态栏项宽度：与系统菜单栏图标常用宽度接近（约 28pt），
        // 即便符号尺寸随系统字体变化，菜单栏也不会左右抖动、且与相邻图标间距合理。
        statusItem?.length = Self.iconCanvasSize.width + 4
        button.toolTip = IadenteL10n.t("音量：\(sys.deviceName)", "Volume: \(sys.deviceName)")
    }

    private func observeState() {
        // 静音 / 音量变化 → 换图标。两者在主线程发布，直接 sink 即可。
        SystemVolumeObserver.shared.$muted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        SystemVolumeObserver.shared.$volume
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        // 显隐开关变化 → 重建图标。
        Task { [weak self] in
            for await _ in Defaults.updates(.showVolumeStatusBarIcon, initial: false) {
                self?.rebuildItem()
            }
        }

        installDefaultDeviceListeners()
    }

    // MARK: - 系统默认设备变化监听

    /// 监听系统「默认输入 / 输出设备」变化，变化时广播通知让弹窗刷新。
    /// 这样无论快捷键、设置页还是系统在别处改了默认设备，音量弹窗都能实时同步，
    /// 避免「切了但界面没变」的错觉。
    private var defaultDeviceListenerBlocks: [AudioObjectPropertyListenerBlock] = []

    private func installDefaultDeviceListeners() {
        guard defaultDeviceListenerBlocks.isEmpty else { return }
        let cb: AudioObjectPropertyListenerBlock = { _, _ in
            NotificationCenter.default.post(name: .volumeDefaultDeviceChanged, object: nil)
        }
        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &inAddr, DispatchQueue.main, cb)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outAddr, DispatchQueue.main, cb)
        defaultDeviceListenerBlocks = [cb, cb]
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard statusItem != nil else { return }
        if isPanelVisible {
            closePanel()
            return
        }
        showPanel()
    }

    var isPanelVisible: Bool { panel?.isVisible == true }

    private func startAppearanceObservation() {
        Task { [weak self] in
            for await _ in Defaults.updates(.appearanceMode, initial: false) {
                self?.applyAppearance()
            }
        }
    }

    private func applyAppearance() {
        panel?.appearance = Defaults[.appearanceMode].nsAppearance
    }

    // MARK: - 面板几何与生命周期

    /// 「状态栏按钮下沿 → Dock 上缘」之间的可用高度。
    private func availableHeightBelowStatusBar() -> CGFloat {
        guard let anchor = statusButtonScreenFrame() else {
            let h = NSScreen.main?.visibleFrame.height ?? 900
            return max(200, h - 12)
        }
        let visible = anchor.screen.visibleFrame
        let top = min(anchor.frame.minY - Self.panelGap, visible.maxY)
        return max(200, top - visible.minY - Self.screenMargin)
    }

    /// 面板应该占据的屏幕矩形：顶边贴菜单栏下沿，水平中心对齐状态栏按钮中心。
    private func panelFrame(height: CGFloat) -> NSRect {
        let width = VolumePopoverMetrics.width
        guard let anchor = statusButtonScreenFrame() else {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(x: visible.midX - width / 2,
                          y: visible.maxY - height,
                          width: width, height: height)
        }
        let screenFrame = anchor.screen.frame
        let visible = anchor.screen.visibleFrame
        let top = min(anchor.frame.minY - Self.panelGap, visible.maxY)

        // 水平：按钮中心正下方。只有真的会越出屏幕才夹取，且夹取量最小。
        var x = anchor.frame.midX - width / 2
        let minX = screenFrame.minX + Self.screenMargin
        let maxX = screenFrame.maxX - width - Self.screenMargin
        if maxX >= minX { x = min(max(x, minX), maxX) }

        // 垂直：向下生长，底部不越过 Dock 上缘。
        let maxHeight = max(160, top - visible.minY - Self.screenMargin)
        let h = min(height, maxHeight)
        return NSRect(x: x.rounded(), y: (top - h).rounded(), width: width, height: h.rounded())
    }

    /// 取得状态栏按钮在屏幕坐标系中的 frame 及其所在屏幕。
    private func statusButtonScreenFrame() -> (screen: NSScreen, frame: NSRect)? {
        guard let button = statusItem?.button, let win = button.window else { return nil }
        let frame = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = win.screen ?? NSScreen.main else { return nil }
        return (screen, frame)
    }

    private func showPanel() {
        let p = configurePanel()
        let height = desiredPanelHeight()
        let frame = panelFrame(height: height)

        p.setFrame(frame, display: false)
        p.orderFrontRegardless()
        // 某些 level/.statusBar 面板在 orderFront 后会被 WindowServer 微调位置，
        // 这里再强制一次 origin，确保真正对齐到计算出来的位置。
        p.setFrameOrigin(frame.origin)
        p.makeKey()
        installDismissMonitors()
        Log.info(
            "[volume-popover] 打开 @\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))pt"
            + "（可用高度 \(Int(availableHeightBelowStatusBar()))pt）")
    }

    private func desiredPanelHeight() -> CGFloat {
        let available = availableHeightBelowStatusBar()
        let natural = VolumePopoverMetrics.initialHeight
        return min(max(natural, VolumePopoverMetrics.minContentHeight), available)
    }

    func closePanel() {
        removeDismissMonitors()
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        Log.info("[volume-popover] 关闭")
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { _ in
            MainActor.assumeIsolated { VolumeStatusBarManager.activeInstance?.closePanel() }
        }) {
            dismissMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if event.window === self.statusItem?.button?.window { return event }
            self.closePanel()
            return event
        }) {
            dismissMonitors.append(local)
        }

        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            self.closePanel()
            return nil
        }) {
            dismissMonitors.append(key)
        }
    }

    private func removeDismissMonitors() {
        for m in dismissMonitors { NSEvent.removeMonitor(m) }
        dismissMonitors.removeAll()
    }

    private static weak var activeInstance: VolumeStatusBarManager?
}

/// 音量状态栏下拉面板。无边框 + 非激活，但必须能成为 key 窗口，
/// 否则里面的按钮 / 滚动条 / 滑杆收不到点击。
private final class VolumePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 弹窗尺寸

enum VolumePopoverMetrics {
    /// 弹窗宽度。精简为 320，与系统监控弹窗一致，突出「主音量 / 输入 / 输出 / App」四模块。
    static let width: CGFloat = 320
    /// 首次展示时的占位高度，随后由内容实测高度接管。
    static let initialHeight: CGFloat = 420
    /// 底部固定栏高度（分隔线 1 + 按钮 39）。
    static let footerHeight: CGFloat = 40
    /// 内容最小高度，避免测量到位前弹窗被压成一条缝。
    static let minContentHeight: CGFloat = 120

    /// 弹窗允许的最大高度：屏幕可视区再留出菜单栏 + 呼吸空间。
    /// 内容超过它时才启用滚动（平时「有多长显示多长」，不出现下拉条）。
    static var maxHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, visible - 48)
    }
}

/// 用于把内容自然高度回传给弹窗容器。
private struct VolumeContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 音量管理弹窗内容
//
// 结构（无顶栏，三个卡片 + 固定底栏，FineTune 风格 + macall 设计系统）：
//   · 「主音量」模块：当前输出/输入设备（仅显示，不可切换）+ 滑杆 + 音量百分比 + 静音图标 + 麦克风图标
//   · 可折叠「App 音量」模块：全部活跃 App，每行可单独调音量、路由，可「隐藏」；
//     底部「已隐藏的应用」折叠区可随时恢复
//   · 可折叠「输出设备切换」模块：单选系统默认输出（含「跟随系统」），点选即切换
//   · 底部固定栏：打开音量设置
//
// 高度策略：内容有多高就显示多高（不出现下拉条）；只有当内容超过屏幕可视高度时，
// 才把内容区钉到上限并允许滚动，同时在底部显示「还有更多」的提示箭头。

private struct VolumeControlPopover: View {
    @ObservedObject var model: SettingsModel
    let onOpenSettings: () -> Void
    /// 把「内容 + 底栏」的实际总高度回传给 NSPopover，用于同步 contentSize。
    let onHeightChange: (CGFloat) -> Void

    @ObservedObject private var sys = SystemVolumeObserver.shared
    private var engine: PerAppAudioEngine { PerAppAudioEngine.shared }

    @State private var devices: [AudioDeviceInfo] = []
    @State private var inputDevices: [AudioDeviceInfo] = []
    @State private var inputName: String = ""
    @State private var micMuted: Bool = false
    @State private var micAvailable: Bool = false
    @State private var showHidden: Bool = false
    @State private var expandAppSection: Bool = true
    @State private var expandOutputSection: Bool = true
    @State private var expandInputSection: Bool = true
    @State private var contentHeight: CGFloat = VolumePopoverMetrics.initialHeight
    /// 本地镜像逐 App 音频引擎检测到的活跃 App；通过通知同步，确保 SwiftUI 可靠刷新。
    @State private var perAppApps: [AudioApp] = []

    /// 订阅「弹窗模块」设置，让顺序 / 显隐变化实时驱动渲染（而非等视图偶然刷新）。
    @Default(.volumeModuleOrder) private var volumeModuleOrder
    @Default(.volumeHiddenModules) private var volumeHiddenModules
    /// 顶部设备胶囊点击后弹出的设备选择小浮层显隐。
    @State private var showOutputDevicePicker: Bool = false
    @State private var showInputDevicePicker: Bool = false

    /// 当前选中的输出设备 UID；配置恰好一个时即为该项，否则（空或旧版多 UID）视为「跟随系统」。
    private var selectedUID: String? {
        let cfg = model.config.outputDeviceUIDs
        return cfg.count == 1 ? cfg[0] : nil
    }

    private var visibleApps: [AudioApp] {
        let hidden = Set(model.config.hiddenAudioApps)
        return perAppApps.filter { !hidden.contains($0.persistenceKey) }
    }

    private var hiddenEntries: [(key: String, name: String)] {
        model.config.hiddenAudioApps.compactMap { key in
            // 守护进程 / 无主通用辅助进程（如 CoreSpeech、helper）本就不该出现在列表，
            // 即便历史残留也在此过滤掉，避免「已隐藏的应用」区再出现它们。
            guard !AudioProcessMonitor.isSystemDaemon(bundleID: key, name: key) else { return nil }
            return (key: key, name: model.config.hiddenAudioAppNames[key] ?? key)
        }
    }

    // MARK: - 高度计算

    /// 内容区可用高度（屏幕上限扣掉底栏）。
    private var availableContentHeight: CGFloat {
        VolumePopoverMetrics.maxHeight - VolumePopoverMetrics.footerHeight
    }

    /// 内容自然高度是否已经顶到屏幕上限。
    private var needsScroll: Bool {
        contentHeight > availableContentHeight + 0.5
    }

    /// 内容区最终高度：能放下就用自然高度，放不下才钉到上限。
    private var resolvedContentHeight: CGFloat {
        min(max(contentHeight, VolumePopoverMetrics.minContentHeight), availableContentHeight)
    }

    var body: some View {
        ZStack {
            IadenteWindowBackdrop()

            VStack(spacing: 0) {
                contentArea
                footerView
            }
        }
        .frame(
            width: VolumePopoverMetrics.width,
            height: resolvedContentHeight + VolumePopoverMetrics.footerHeight
        )
        .onPreferenceChange(VolumeContentHeightKey.self) { h in
            guard h > 1, abs(h - contentHeight) > 0.5 else { return }
            contentHeight = h
        }
        .onChange(of: resolvedContentHeight) { _, _ in reportHeight() }
        .onAppear {
            PerAppAudioEngine.shared.refreshNow()
            perAppApps = engine.activeApps
            refresh()
            reportHeight()
            // 布局稳定后再核一次高度：首帧设备/App 列表尚未就位时，
            // 内容偏短，等数据填充后高度变化需再次回传，避免底部卡片被裁切。
            DispatchQueue.main.async { reportHeight() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("perAppAppsChanged"))) { _ in
            perAppApps = engine.activeApps
        }
        .onReceive(NotificationCenter.default.publisher(for: .volumeDefaultDeviceChanged)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .volumeInputMuteChanged)) { _ in
            refresh()
        }
    }

    private func reportHeight() {
        onHeightChange(resolvedContentHeight + VolumePopoverMetrics.footerHeight)
    }

    /// 按「弹窗模块」设置确定呈现的模块序列：
    /// 顺序取 `volumeModuleOrder`，隐藏集（`volumeHiddenModules`）中的模块不渲染；
    /// `master`（主音量）为常驻模块，永远渲染——即便配置损坏漏了它也会兜底补回。
    private var renderModules: [VolumeModule] {
        let hidden = Set(volumeHiddenModules)
        let filtered = volumeModuleOrder.filter { $0 == .master || !hidden.contains($0) }
        return filtered.contains(.master) ? filtered : [.master] + filtered
    }

    /// 内容区。平时完全按自然高度铺开（无下拉条）；
    /// 超出屏幕时钉到上限并开放滚动，底部给一个「还有更多」的提示。
    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(renderModules) { module in
                    switch module {
                    case .master: masterVolumeCard
                    case .input:  inputDeviceCard
                    case .output: outputDeviceCard
                    case .app:    appVolumeCard
                    }
                }
            }
            .padding(12)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: VolumeContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .scrollIndicators(.never)
        .scrollDisabled(!needsScroll)
        .frame(height: resolvedContentHeight)
        .overlay(alignment: .bottom) {
            if needsScroll { overflowHint }
        }
    }

    /// 超出屏幕后的兜底提示：内容被截断时告诉用户还能往下滚。
    private var overflowHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 11, weight: .bold))
            Text(IadenteL10n.t("内容超出屏幕，可继续滚动", "Content exceeds the screen — scroll for more"))
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.bottom, 6)
        .allowsHitTesting(false)
    }

    // MARK: - 主音量模块（含当前输入 / 输出设备）

    private var masterVolumeCard: some View {
        IadenteCard(
            IadenteL10n.t("主音量", "Master Volume"),
            icon: "speaker.wave.2.fill",
            colors: IadenteTheme.advancedColors,
            trailingSpacer: false,
            trailing: { masterVolumeHeaderDevices }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 顶部设备胶囊点选后，在卡片内就地展开对应设备列表（避免独立窗口弹窗
                // 在 non-activating NSPanel 下被瞬间 dismiss 的问题）。
                if showOutputDevicePicker {
                    devicePickerSheet(title: IadenteL10n.t("选择输出设备", "Choose output device")) {
                        outputDevicePicker
                    }
                }
                if showInputDevicePicker {
                    devicePickerSheet(title: IadenteL10n.t("选择输入设备", "Choose input device")) {
                        inputDevicePicker
                    }
                }
                HStack(spacing: 10) {
                    Slider(value: $sys.volume, in: 0...1)
                        .tint(sys.muted ? IadenteTheme.coral : IadenteTheme.jade)
                        .disabled(!sys.volumeControllable)

                    Text(sys.volumeControllable ? "\(Int(sys.volume * 100))%" : "—")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(sys.muted ? IadenteTheme.coral : Color.secondary)
                        .frame(width: 42, alignment: .trailing)

                    iconToggle(
                        icon: "speaker.wave.2.fill",
                        crossed: "speaker.slash.fill",
                        on: sys.muted,
                        enabled: true,
                        help: IadenteL10n.t("静音", "Mute")
                    ) {
                        sys.muted.toggle()
                    }

                    iconToggle(
                        icon: "mic.fill",
                        crossed: "mic.slash.fill",
                        on: micMuted,
                        enabled: micAvailable,
                        help: micAvailable
                            ? IadenteL10n.t("麦克风", "Microphone") + (inputName.isEmpty ? "" : "：\(inputName)")
                            : IadenteL10n.t("麦克风不可控", "Microphone not controllable")
                    ) {
                        let target = !micMuted
                        if VolumeCore.setInputMute(target) {
                            micMuted = target
                        } else {
                            micMuted = VolumeCore.getInputMute() ?? micMuted
                        }
                    }
                }

                if !sys.volumeControllable {
                    Text(IadenteL10n.t(
                        "当前主播放设备不支持软件音量调节",
                        "The current master output device does not support software volume control"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 标题右侧当前输出设备名：单设备配置显示该设备名；跟随系统时显示系统当前默认设备名。
    private var outputDisplayText: String {
        let uids = model.config.outputDeviceUIDs
        if uids.count == 1, let name = devices.first(where: { $0.uid == uids[0] })?.name {
            return name
        }
        return sys.deviceName.isEmpty
            ? IadenteL10n.t("未检测到音频设备", "No audio devices")
            : sys.deviceName
    }

    private var outputActive: Bool {
        !model.config.outputDeviceUIDs.isEmpty || !sys.deviceName.isEmpty
    }

    /// 标题右侧：当前输出设备 + 输入设备，上下排列、居中；两行均为可点击胶囊，
    /// 点击后分别在卡片内就地展开设备选择列表（与下方「输出设备 / 输入设备」卡片一致），点选即切换。
    private var masterVolumeHeaderDevices: some View {
        GeometryReader { geo in
            let maxTextWidth = max(geo.size.width - 8, 60)
            VStack(spacing: 5) {
                headerDeviceRow(
                    icon: "speaker.wave.2.fill",
                    name: outputDisplayText,
                    active: outputActive,
                    maxWidth: maxTextWidth
                )
                .contentShape(Rectangle())
                .help(IadenteL10n.t("点击选择输出设备", "Choose output device"))
                .onTapGesture {
                    showInputDevicePicker = false
                    showOutputDevicePicker.toggle()
                }

                headerDeviceRow(
                    icon: micMuted ? "mic.slash.fill" : "mic.fill",
                    name: inputName.isEmpty
                        ? IadenteL10n.t("无输入设备", "No input device")
                        : inputName,
                    active: !inputName.isEmpty,
                    maxWidth: maxTextWidth
                )
                .contentShape(Rectangle())
                .help(IadenteL10n.t("点击选择输入设备", "Choose input device"))
                .onTapGesture {
                    showOutputDevicePicker = false
                    showInputDevicePicker.toggle()
                }
            }
            .frame(maxWidth: geo.size.width, alignment: .center)
        }
    }

    /// 顶部输出设备胶囊弹出的设备选择小浮层。
    private var outputDevicePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            if devices.isEmpty {
                emptyDeviceHint
            } else {
                ForEach(Array(devices.enumerated()), id: \.element.uid) { idx, dev in
                    devicePickerRow(name: dev.name, selected: selectedUID == dev.uid) {
                        commitSelection([dev.uid])
                        showOutputDevicePicker = false
                    }
                    if idx < devices.count - 1 { Divider().padding(.leading, 26) }
                }
            }
        }
        .padding(6)
        .frame(width: 240)
    }

    /// 顶部输入设备胶囊弹出的设备选择小浮层。
    private var inputDevicePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            if inputDevices.isEmpty {
                emptyDeviceHint
            } else {
                ForEach(Array(inputDevices.enumerated()), id: \.element.uid) { idx, dev in
                    devicePickerRow(name: dev.name, selected: selectedInputUID == dev.uid) {
                        commitInputSelection(dev.uid)
                        showInputDevicePicker = false
                    }
                    if idx < inputDevices.count - 1 { Divider().padding(.leading, 26) }
                }
            }
        }
        .padding(6)
        .frame(width: 240)
    }

    /// 把设备选择列表包成一张带标题的小卡片，使其看起来像顶部点出的「小弹窗」，
    /// 但实际渲染在同一个 NSPanel 内（就地下拉），不存在跨窗口焦点丢失 / 被秒关的问题。
    private func devicePickerSheet(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    showOutputDevicePicker = false
                    showInputDevicePicker = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(IadenteL10n.t("关闭", "Close"))
            }
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private var emptyDeviceHint: some View {
        Text(IadenteL10n.t("未枚举到音频设备。", "No audio devices enumerated."))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(8)
    }

    /// 设备选择浮层里的单行：样式与下方卡片设备行一致（选中打勾 + 名称）。
    private func devicePickerRow(name: String, selected: Bool, onPick: @escaping () -> Void) -> some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? IadenteTheme.jade : Color.secondary)
                Text(name)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }

    /// 标题右侧单行设备信息：图标 + 设备名，整体在右侧空间居中；名称最多 maxWidth，超长省略。透明无底色。
    private func headerDeviceRow(icon: String, name: String, active: Bool, maxWidth: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(active ? IadenteTheme.jade : Color.secondary)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.primary.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: maxWidth, alignment: .center)
        .help(name)
    }

    /// 图标开关按钮：开启时换成「打叉」图标并填充高亮色。
    private func iconToggle(
        icon: String,
        crossed: String,
        on: Bool,
        enabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: on ? crossed : icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? IadenteTheme.coral : Color.primary.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    // MARK: - 折叠按钮

    private func collapseButton(expanded: Binding<Bool>) -> some View {
        // 外层 HStack 撑满标题栏剩余宽度，左侧 Spacer 把折叠按钮推到标题栏最右侧。
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.wrappedValue.toggle() }
            } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .help(expanded.wrappedValue
                  ? IadenteL10n.t("折叠", "Collapse")
                  : IadenteL10n.t("展开", "Expand"))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 第一部分：App 音量

    private var appVolumeCard: some View {
        IadenteCard(
            IadenteL10n.t("App 音量", "App Volume"),
            icon: "speaker.wave.2.bubble.left.fill",
            colors: IadenteTheme.advancedColors,
            trailing: { collapseButton(expanded: $expandAppSection) }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if expandAppSection {
                    Group {
                        if !Permissions.isScreenRecordingTrusted() {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(IadenteTheme.amber)
                                Text(IadenteL10n.t(
                                    "逐 App 音量需要「屏幕录制」权限（macOS 用它授权音频拦截）。",
                                    "Per-app volume needs Screen Recording permission (macOS uses it to authorize audio interception)."))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Button(IadenteL10n.t("去开启", "Open")) {
                                    Permissions.requestScreenRecording()
                                    Permissions.openScreenRecordingSettings()
                                }
                                .controlSize(.small)
                                .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.advancedColors))
                            }
                        } else if visibleApps.isEmpty {
                            Text(hiddenEntries.isEmpty
                                 ? IadenteL10n.t(
                                    "当前没有 App 在播放声音。开始播放后这里会出现可控制的 App。",
                                    "No apps are playing audio right now. Playing something lists it here.")
                                 : IadenteL10n.t(
                                    "当前活跃的 App 都已被隐藏。",
                                    "All active apps are currently hidden."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(Array(visibleApps.enumerated()), id: \.element.id) { index, app in
                                PerAppPopoverRow(app: app, model: model)
                                if index < visibleApps.count - 1 {
                                    IadenteRowDivider()
                                        .padding(.leading, 28)
                                }
                            }
                        }

                        if !hiddenEntries.isEmpty {
                            IadenteRowDivider()
                                .padding(.vertical, 6)
                            hiddenAppsSection
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    /// 「已隐藏的应用」折叠区：被隐藏的 App 依然被检测，这里随时恢复显示。
    private var hiddenAppsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showHidden.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(IadenteL10n.t("已隐藏的应用", "Hidden Apps") + " (\(hiddenEntries.count))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: showHidden ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if showHidden {
                        Button(IadenteL10n.t("全部恢复", "Restore All")) { restoreAllHidden() }
                            .controlSize(.small)
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(IadenteTheme.jade)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHidden {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(hiddenEntries, id: \.key) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(entry.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Button {
                                restoreHidden(entry.key)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 9))
                                    Text(IadenteL10n.t("恢复", "Restore"))
                                        .font(.system(size: 10.5))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.primary.opacity(0.07))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private func restoreHidden(_ key: String) {
        model.config.hiddenAudioApps.removeAll { $0 == key }
        model.config.hiddenAudioAppNames.removeValue(forKey: key)
        model.save()
    }

    private func restoreAllHidden() {
        model.config.hiddenAudioApps.removeAll()
        model.config.hiddenAudioAppNames.removeAll()
        model.save()
        showHidden = false
    }

    // MARK: - 第二部分：输出设备（单选系统默认输出）

    private var outputDeviceCard: some View {
        IadenteCard(
            IadenteL10n.t("输出设备", "Output Device"),
            icon: "hifispeaker.2.fill",
            colors: IadenteTheme.advancedColors,
            trailing: { collapseButton(expanded: $expandOutputSection) }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if expandOutputSection {
                    Group {
                        Text(IadenteL10n.t(
                            "点选设备即设为系统默认输出；选「跟随系统」恢复由 macOS 控制。",
                            "Pick a device to make it the system default; choose System default to let macOS decide."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 6)

                        if devices.isEmpty {
                            Text(IadenteL10n.t("未枚举到输出设备。", "No output devices enumerated."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            systemDefaultRow
                            IadenteRowDivider().padding(.leading, 26)
                            ForEach(Array(devices.enumerated()), id: \.element.uid) { index, dev in
                                deviceRow(dev)
                                if index < devices.count - 1 {
                                    IadenteRowDivider().padding(.leading, 26)
                                }
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    /// 「跟随系统」：交还 macOS 控制默认输出。
    private var systemDefaultRow: some View {
        let selected = selectedUID == nil
        return Button {
            commitSelection([])
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? IadenteTheme.jade : Color.secondary)
                Text(IadenteL10n.t("跟随系统", "System default"))
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(IadenteL10n.t("由 macOS 控制默认输出", "Let macOS choose the default output"))
    }

    private func deviceRow(_ dev: AudioDeviceInfo) -> some View {
        let selected = selectedUID == dev.uid
        return Button {
            commitSelection([dev.uid])
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? IadenteTheme.jade : Color.secondary)
                Text(dev.name)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if dev.isDefault {
                    Text(IadenteL10n.t("当前", "Active"))
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(IadenteTheme.jade.opacity(0.18))
                        )
                        .foregroundStyle(IadenteTheme.jade)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(IadenteL10n.t("设为系统默认输出", "Set as system default output"))
        .padding(.vertical, 5)
    }

    /// 按用户自定义顺序排列设备；未记录过的新设备排在末尾。
    private func applyOrder(_ raw: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        let order = model.config.audioDeviceOrder
        guard !order.isEmpty else { return raw }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return raw.enumerated().sorted { a, b in
            let ra = rank[a.element.uid] ?? (order.count + a.offset)
            let rb = rank[b.element.uid] ?? (order.count + b.offset)
            return ra < rb
        }.map { $0.element }
    }

    /// 写入 Configuration.outputDeviceUIDs 并立即切换系统默认输出（单设备）；
    /// 传入空数组＝跟随系统，不强制。稍后回读一次以刷新「当前」标记。
    private func commitSelection(_ uids: [String]) {
        model.config.outputDeviceUIDs = uids
        model.save()
        if let uid = uids.first, let dev = VolumeCore.deviceWithUID(uid) {
            VolumeCore.setDefaultOutputDevice(dev)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { refresh() }
    }

    // MARK: - 第二部分（续）：输入设备（麦克风）

    /// 当前系统默认输入设备 UID；用于高亮选中行。
    private var selectedInputUID: String? {
        CoreAudioHelpers.defaultInputDeviceUID()
    }

    /// 写入系统默认输入设备并立即切换；稍后回读刷新「当前」标记。
    private func commitInputSelection(_ uid: String) {
        if let id = VolumeCore.inputDeviceWithUID(uid) {
            VolumeCore.setDefaultInputDevice(id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh() }
    }

    private var inputDeviceCard: some View {
        IadenteCard(
            IadenteL10n.t("输入设备", "Input Device"),
            icon: "mic.fill",
            colors: IadenteTheme.advancedColors,
            trailing: { collapseButton(expanded: $expandInputSection) }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if expandInputSection {
                    Group {
                        // 麦克风静音总开关：与「主音量」模块里的麦克风图标联动同一状态。
                        HStack(spacing: 8) {
                            Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(micMuted ? IadenteTheme.coral : IadenteTheme.jade)
                            Text(IadenteL10n.t("麦克风", "Microphone"))
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer(minLength: 4)
                            Toggle("", isOn: Binding(get: { micMuted }, set: { target in
                                if VolumeCore.setInputMute(target) {
                                    micMuted = target
                                } else {
                                    micMuted = VolumeCore.getInputMute() ?? micMuted
                                }
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!micAvailable)
                            .tint(IadenteTheme.coral)
                        }
                        .padding(.bottom, 6)

                        if inputDevices.isEmpty {
                            Text(IadenteL10n.t("未枚举到输入设备。", "No input devices enumerated."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(inputDevices.enumerated()), id: \.element.uid) { index, dev in
                                inputDeviceRow(dev)
                                if index < inputDevices.count - 1 {
                                    IadenteRowDivider().padding(.leading, 26)
                                }
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func inputDeviceRow(_ dev: AudioDeviceInfo) -> some View {
        let selected = selectedInputUID == dev.uid
        return Button {
            commitInputSelection(dev.uid)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? IadenteTheme.jade : Color.secondary)
                Text(dev.name)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if dev.isDefault {
                    Text(IadenteL10n.t("当前", "Active"))
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(IadenteTheme.jade.opacity(0.18))
                        )
                        .foregroundStyle(IadenteTheme.jade)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(IadenteL10n.t("设为系统默认输入", "Set as system default input"))
        .padding(.vertical, 5)
    }

    // MARK: - 底部固定栏

    private var footerView: some View {
        VStack(spacing: 0) {
            IadenteRowDivider()
            Button {
                onOpenSettings()
            } label: {
                Label(
                    IadenteL10n.t("打开音量设置", "Open Volume Settings"),
                    systemImage: "gearshape.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: VolumePopoverMetrics.footerHeight - 1)
            }
            .buttonStyle(.plain)
        }
        .frame(height: VolumePopoverMetrics.footerHeight)
    }

    private func refresh() {
        sys.refreshFromSystem()
        // 隐藏 macall 自建的多输出聚合设备：它是实现细节，不参与用户选择
        let raw = VolumeCore.outputDevices().filter { !$0.name.hasPrefix("macall 多输出") }
        devices = applyOrder(raw)
        inputDevices = VolumeCore.inputDevices().filter { !$0.name.hasPrefix("macall 多输出") }
        inputName = CoreAudioHelpers.defaultInputDeviceName() ?? ""
        micAvailable = VolumeCore.inputMuteAvailable()
        micMuted = VolumeCore.getInputMute() ?? false
    }
}

// MARK: - 逐 App 音量行（FineTune AppRow 风格）
//
// 只要被检测到就会显示（播放中 / 暂停但音频会话仍活跃），不需要单独控制的也在列。
// 图标按钮可点击激活该 App；右侧依次是「隐藏」「静音」「接管开关」。
// 接管后展开：音量滑杆(0...2) + 百分比、路由 Menu、忽略(取消接管)。
// 所有改动写入 model.config.perAppVolume / perAppMuted / perAppDeviceUIDs 并 model.save()。

private struct PerAppPopoverRow: View {
    let app: AudioApp
    @ObservedObject var model: SettingsModel

    private var key: String { app.persistenceKey }
    private var controlled: Bool { model.config.perAppVolume[key] != nil }

    @State private var vol: Double = 1.0
    @State private var muted: Bool = false

    init(app: AudioApp, model: SettingsModel) {
        self.app = app
        self.model = model
        let key = app.persistenceKey
        _vol = State(initialValue: model.config.perAppVolume[key] ?? 1.0)
        _muted = State(initialValue: model.config.perAppMuted[key] ?? false)
    }

    private var devices: [AudioDeviceInfo] { VolumeCore.outputDevices() }
    private var routeLabel: String {
        let uids = model.config.perAppDeviceUIDs[key] ?? []
        guard uids.isEmpty else {
            return devices.first { $0.uid == uids[0] }?.displayName ?? uids[0]
        }
        return IadenteL10n.t("跟随系统", "System default")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 第一行：图标(可点激活) + 名称/设备选择 + 静音 + 均衡器 + 隐藏 + 接管开关
            HStack(spacing: 8) {
                Button {
                    NSRunningApplication(processIdentifier: app.id)?.activate()
                } label: {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .cornerRadius(4)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 14))
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.plain)
                .help(IadenteL10n.t("点击图标可激活此 App", "Tap the icon to activate this app"))

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if controlled {
                        deviceMenu
                            .font(.system(size: 10))
                    }
                }

                Spacer(minLength: 6)

                if controlled {
                    Button {
                        muted.toggle()
                        model.config.perAppMuted[key] = muted
                        model.save()
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .foregroundStyle(muted ? IadenteTheme.coral : .secondary)
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .help(IadenteL10n.t("静音", "Mute"))
                }

                Button {
                    hideApp()
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(IadenteL10n.t("隐藏", "Hide"))

                Toggle("", isOn: Binding(get: { controlled }, set: { on in
                    if on {
                        model.config.perAppVolume[key] = 1.0
                        model.config.perAppMuted[key] = false
                    } else {
                        model.config.perAppVolume.removeValue(forKey: key)
                        model.config.perAppMuted.removeValue(forKey: key)
                        model.config.perAppDeviceUIDs.removeValue(forKey: key)
                    }
                    model.save()
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(IadenteTheme.advancedColors.first ?? IadenteTheme.jade)
            }

            if controlled {
                // 第二行：音量滑杆 + 百分比
                HStack(spacing: 6) {
                    Slider(value: $vol, in: 0...2)
                        .onChange(of: vol) { _, newValue in
                            model.config.perAppVolume[key] = newValue
                            model.save()
                        }
                        .tint(IadenteTheme.jade)
                    Text("\(Int(vol * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 3)
    }

    /// 名称下方可点击的播放设备选择（Menu 标签即当前选中设备 / 跟随系统）。
    private var deviceMenu: some View {
        Menu {
            Button(IadenteL10n.t("跟随系统", "System default")) {
                model.config.perAppDeviceUIDs[key] = []
                model.save()
            }
            ForEach(devices) { dev in
                Button(dev.displayName) {
                    model.config.perAppDeviceUIDs[key] = [dev.uid]
                    model.save()
                }
            }
        } label: {
            Text(routeLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
    }

    /// 隐藏此 App（仅影响弹窗展示，检测与已生效的音量处理保持不变）。
    private func hideApp() {
        // 守护进程 / 无主通用辅助进程不允许隐藏（隐藏后仍会被「已隐藏」区过滤，
        // 用户也无法恢复——不如直接禁止，避免产生无意义残留记录）。
        guard !AudioProcessMonitor.isSystemDaemon(bundleID: app.bundleID, name: app.name) else { return }
        model.config.hiddenAudioAppNames[key] = app.name
        if !model.config.hiddenAudioApps.contains(key) {
            model.config.hiddenAudioApps.append(key)
        }
        model.save()
    }
}
