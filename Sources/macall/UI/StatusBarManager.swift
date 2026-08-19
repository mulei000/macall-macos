import AppKit
import SwiftUI

@MainActor
final class StatusBarManager: NSObject {
    private let statusItem: NSStatusItem
    private let viewModel: MenuViewModel
    private let settingsWindowController: SettingsWindowController
    private let energyAppsWindowController = EnergyAppsWindowController()

    /// monitor 总开关状态读取（主开关）。图标显隐的次级开关 `statusBarIconVisible` 仅
    /// 在 monitor 启用时生效；monitor 关闭则图标强制隐藏，体现「主-次」层级。
    private let isMonitorEnabled: () -> Bool

    /// monitor 总开关变化观察器（保活令牌）。
    private var monitorEnabledObserver: NSObjectProtocol?

    // MARK: - 下拉面板
    //
    // ## 为什么不再用 NSPopover
    //
    // NSPopover 自己决定水平位置，且有两条无法关掉的行为：
    //   1. **锚点视图宽度一变它就跟着挪。** 状态栏里的 CPU / 内存 / 功率读数每秒都在改变
    //      `statusItem.length`，于是弹窗肉眼可见地左右漂移。
    //   2. **靠近屏幕右缘时它会把整个弹窗平移回屏幕内**，箭头却留在原处，看着更歪。
    //
    // 需求是「固定在状态栏图标正下方、不能偏移」，这两条都必须绕开，所以换成自己摆位的
    // 无边框面板：顶边永远贴菜单栏下沿，水平永远对齐状态栏按钮中心，只有真的越出屏幕
    // 才做最小夹取。高度同样完全由我们掌控，不会被 NSPopover 翻转到菜单栏上方去。
    private var panel: DashboardPanel?
    private var hosting: NSHostingController<DashboardPopoverView>?
    /// 面板打开期间安装的「点外面就关」监听器，关闭时必须全部摘掉，否则会一直吃事件。
    private var dismissMonitors: [Any] = []

    /// 面板固定宽度。
    private static let panelWidth: CGFloat = 320
    /// 面板顶边与菜单栏下沿之间的缝隙。
    private static let panelGap: CGFloat = 4
    /// 面板离屏幕左右 / 底部（Dock 上缘）的最小留白。
    private static let screenMargin: CGFloat = 4

    /// 面板打开期间冻结状态栏宽度。
    /// 否则读数位数一变 `statusItem.length` 就变，按钮中心跟着移动，
    /// 下一轮 resize 重新摆位时面板会横向跳一下——这正是「偏移」的来源之一。
    private var statusWidthFrozen = false

    /// 最近一次由 SwiftUI 报上来的内容区自然高度（不含底部固定栏）。
    private var lastRegionHeight: CGFloat = 480

    var isPanelVisible: Bool { panel?.isVisible == true }

    init(
        viewModel: MenuViewModel,
        settingsWindowController: SettingsWindowController,
        isMonitorEnabled: @escaping () -> Bool
    ) {
        self.viewModel = viewModel
        self.settingsWindowController = settingsWindowController
        self.isMonitorEnabled = isMonitorEnabled
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()

        // 关键修复：先给一个显式保底宽度，打破「button 无 image/title → 0 宽 →
        // NSHostingView 被压成 0 宽 → SwiftUI 量不到宽度 → length 恒为 0 → 状态项不可见」
        // 的塌陷。否则按钮不会因挂了子视图就自动长大，状态项永远 0 宽消失。
        // 真正的宽度随后由 SwiftUI 的 StatusBarWidthKey 回传、applyStatusItemWidth 接管。
        statusItem.length = 140

        // 图标显隐由「系统监控总开关（主）」与「显示菜单栏图标（次）」共同决定：
        // 仅当 monitor 启用且用户未隐藏图标时才出现。
        applyIconVisibility()
        // 用户运行中切换图标显隐、或切换 monitor 总开关时实时生效，无需重启。
        startIconVisibilityObservation()
        startMonitorEnabledObservation()
        startAppearanceObservation()
    }

    // MARK: - 内容

    private func makeDashboardRootView(
        onContentHeight: @escaping (CGFloat) -> Void
    ) -> DashboardPopoverView {
        DashboardPopoverView(
            viewModel: viewModel,
            onOpenSettings: { [weak self] tab in
                guard let self else { return }
                self.closePanel()
                self.settingsWindowController.showSettings(tab: tab)
            },
            onQuit: { [weak self] in
                self?.viewModel.quit()
            },
            onShowAllEnergyApps: { [weak self] in
                guard let self else { return }
                self.closePanel()
                self.energyAppsWindowController.show()
            },
            onContentHeight: onContentHeight,
            maxContentHeight: availableHeightBelowStatusBar() - footerHeight
        )
    }

    /// 底部固定栏（设置 / 刷新 / 退出）的高度，已与 DashboardPopoverView.footer 对齐。
    private let footerHeight: CGFloat = 38

    /// 根据弹窗尺寸档位计算最终面板高度（宽度固定 320）。
    /// - 小 / 中：内容区高度封顶到对应档位；内容不足时按实际高度，不强行留白。
    /// - 大：内容自然撑开（不含固定底部栏），完整显示所有已开启的状态模块；
    ///   只有触到「状态栏下沿 → Dock 上缘」这条硬上限时才封顶，此时内部转为滚动。
    private func desiredPanelHeight(regionHeight: CGFloat) -> CGFloat {
        let availableBelow = availableHeightBelowStatusBar()
        let footer = footerHeight
        switch Defaults[.popoverSize] {
        case .small:
            return min(min(regionHeight, 300) + footer, availableBelow)
        case .medium:
            return min(min(regionHeight, 480) + footer, availableBelow)
        case .auto:
            return min(regionHeight + footer, availableBelow)
        }
    }

    /// 打开前先取内容区高度：「大」档用离屏测量 contentBody 得到真实内容高度；
    /// 固定档位用档位值即可。
    ///
    /// 注意：`measureContentHeight()` 量的是 `DashboardPopoverView.contentBody`，**本就不含底部栏**，
    /// 这里直接返回它即可——底部栏高度由 `desiredPanelHeight` 统一加回（region + footer）。
    /// 之前错误地又减了一次 `footerHeight`，导致初始面板整体矮 38pt（恰好是底部栏那段），
    /// 运行期几何回调若不触发就无法补回，表现就是「差底部设置那一段、还得滚一下」。
    private func currentRegionHeight() -> CGFloat {
        switch Defaults[.popoverSize] {
        case .small:  return 300
        case .medium: return 480
        case .auto:   return max(0, measureContentHeight())
        }
    }

    /// 在离屏 NSHostingController 中测量 DashboardPopoverView.contentBody 的自然高度。
    /// 只测内容视图（无 ScrollView / 无背景 / 无 footer），避免完整 DashboardPopoverView
    /// 在 sizeThatFits 时因复杂布局断言触发 SIGTRAP。
    private func measureContentHeight() -> CGFloat {
        DashboardPopoverView.measureContentHeight(viewModel: viewModel)
    }

    // MARK: - 几何

    /// 「大」档能延伸到的最大高度 = 状态栏按钮下沿 → Dock 上缘。
    ///
    /// `screen.visibleFrame` 已经扣掉了菜单栏和 Dock，所以 `visibleFrame.minY` 就是 Dock 上缘。
    /// 绝不能用 `buttonFrame.minY - visibleFrame.minY` 之外的野路子换算：在菜单栏坐标系下
    /// 很容易得到接近 0 的值，弹窗会被压成一条透明横条（v0.4.x 踩过）。
    private func availableHeightBelowStatusBar() -> CGFloat {
        guard let anchor = statusButtonScreenFrame() else {
            let h = NSScreen.main?.visibleFrame.height ?? 820
            return max(200, h - 12)
        }
        let visible = anchor.screen.visibleFrame
        let top = min(anchor.frame.minY - Self.panelGap, visible.maxY)
        return max(200, top - visible.minY - Self.screenMargin)
    }

    /// 面板应该占据的屏幕矩形：顶边贴菜单栏下沿，水平中心对齐状态栏按钮中心。
    private func panelFrame(height: CGFloat) -> NSRect {
        let width = Self.panelWidth
        guard let anchor = statusButtonScreenFrame() else {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(x: visible.midX - width / 2,
                          y: visible.maxY - height,
                          width: width, height: height)
        }
        // 水平夹取用整屏 frame：状态栏本身可以盖在 Dock 上方，若用 visibleFrame
        // 水平裁剪会把面板推到 Dock 左侧，导致「图标在右、弹窗却跑到左边」的错位。
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
        let frame = NSRect(x: x.rounded(), y: (top - h).rounded(), width: width, height: h.rounded())
        Log.info("[popover] 定位 anchor=(\(Int(anchor.frame.minX)),\(Int(anchor.frame.minY))-\(Int(anchor.frame.maxY))) midX=\(Int(anchor.frame.midX)) frame=\(frame)")
        return frame
    }

    /// 取得状态栏按钮在屏幕坐标系中的 frame 及其所在屏幕。
    /// 用 button.window.screen 最可靠：status bar window 本身就属于它所在的那块屏，
    /// 用中心点反查 screens 在刘海屏 / 多显示器边界容易误判。
    private func statusButtonScreenFrame() -> (screen: NSScreen, frame: NSRect)? {
        guard let button = statusItem.button, let win = button.window else { return nil }
        let frame = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = win.screen ?? NSScreen.main else { return nil }
        return (screen, frame)
    }

    // MARK: - 面板生命周期

    private func ensurePanel() -> DashboardPanel {
        // 打开时由 SwiftUI 的 onContentHeight 几何回调（见 DashboardPopoverView.body 的
        // GeometryReader + onPreferenceChange）实时报上真实内容高度，这里收到后直接把面板
        // 撑到对应高度。运行期数据变化（如耗电 App 加载完成）会让内容变高，回调会再次触发，
        // 面板随之长高——所以不再需要离屏轮询测量（那种写法会触发 SIGSEGV，见 build 44/45）。
        let onHeight: (CGFloat) -> Void = { [weak self] h in
            guard let self else { return }
            self.lastRegionHeight = h
            self.resizePanel(toRegionHeight: h)
        }

        if let panel, let hosting {
            // 每次打开都刷新一次 rootView，让 maxContentHeight 跟上当前屏幕
            // （外接显示器、Dock 显隐都会改变可用高度）。SwiftUI 会保留 @State。
            hosting.rootView = makeDashboardRootView(onContentHeight: onHeight)
            return panel
        }

        let controller = NSHostingController(rootView: makeDashboardRootView(onContentHeight: onHeight))
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 15
        controller.view.layer?.masksToBounds = true

        let p = DashboardPanel(contentViewController: controller)
        // .nonactivatingPanel：点面板不会把整个 App 激活到最前，和系统菜单栏下拉观感一致。
        p.styleMask = [.borderless, .nonactivatingPanel]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // .statusBar 级别：压住普通窗口和 .floating 的置顶覆盖层，但仍在菜单栏之下。
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
        let p = ensurePanel()
        lastRegionHeight = currentRegionHeight()
        let height = desiredPanelHeight(regionHeight: lastRegionHeight)
        let frame = panelFrame(height: height)

        statusWidthFrozen = true
        p.setFrame(frame, display: false)
        viewModel.menuWillOpen()
        p.orderFrontRegardless()
        // 某些 level/.statusBar 面板在 orderFront 后会被 WindowServer 微调位置，
        // 这里再强制一次 origin，确保真正对齐到计算出来的位置。
        p.setFrameOrigin(frame.origin)
        p.makeKey()
        installDismissMonitors()
        Log.info(
            "[popover] 打开 @\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))pt"
            + "（可用高度 \(Int(availableHeightBelowStatusBar()))pt，内容区 \(Int(lastRegionHeight))pt）")
    }

    func closePanel() {
        removeDismissMonitors()
        guard let p = panel, p.isVisible else {
            statusWidthFrozen = false
            return
        }
        p.orderOut(nil)
        statusWidthFrozen = false
        viewModel.menuDidClose()
        Log.info("[popover] 关闭")
    }

    /// 「大」档自适应高度现在由 SwiftUI 自身的几何回调驱动：DashboardPopoverView 内部的
    /// GeometryReader 量出内容真实高度并通过 `onContentHeight` 上报，本类在 `ensurePanel` 里
    /// 把回调接到 `resizePanel`。运行期数据变化会让内容变高、回调再次触发，面板随之长高，
    /// 因此这里不再做任何离屏轮询测量（那正是 build 44/45 点击状态栏崩溃的根因）。



    /// 内容区高度变化时被调用；按当前档位换算出最终面板高度（含固定底部栏）。
    /// 用 `panelFrame` 重新摆位而不是只改 size——NSWindow 的原点在左下角，
    /// 直接 setContentSize 会让面板"向上长"，顶边就离开菜单栏了。
    private func resizePanel(toRegionHeight regionHeight: CGFloat) {
        lastRegionHeight = regionHeight
        guard let p = panel, p.isVisible else { return }
        let height = desiredPanelHeight(regionHeight: regionHeight)
        let frame = panelFrame(height: height)
        guard frame != p.frame else { return }
        p.setFrame(frame, display: true)
        Log.info("[popover] resize to \(Int(frame.height))pt (region \(Int(regionHeight))pt)")
    }

    // MARK: - 「点外面就关」

    private func installDismissMonitors() {
        removeDismissMonitors()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // 别的 App 里的点击。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { _ in
            MainActor.assumeIsolated { StatusBarManager.activeInstance?.closePanel() }
        }) {
            dismissMonitors.append(global)
        }

        // 本 App 内部的点击：面板自己和状态栏按钮要放行，
        // 否则点状态栏按钮会「先被这里关掉、再被按钮 action 打开」，看着像没反应。
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if event.window === self.statusItem.button?.window { return event }
            self.closePanel()
            return event
        }) {
            dismissMonitors.append(local)
        }

        // Esc 关闭。
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }  // kVK_Escape
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

    /// 全局事件监听回调不带 self，这里留一个弱引用供其取用（进程内只会有一个状态栏管理器）。
    private static weak var activeInstance: StatusBarManager?

    // MARK: - 状态栏按钮

    /// button 早期为 nil 时的重试计数，避免无限重试。
    private var setupRetries = 0
    /// 防止并发/重复启动挂载重试循环（切换图标显隐或 button 尚未就绪时）。
    private var isSettingUpHosting = false
    /// 当前 button 是否已挂载好内容视图。隐藏图标会释放 button，重新显示时 button 可能是
    /// 新实例，必须清掉此标记强制重挂——否则图标回来却空无一物（旧 bug 根因）。
    private var hostingMounted = false

    private func setupPersistentHostingView() {
        // 已有挂载循环在跑（等待 button 就绪）时不重复启动，避免多个重试链叠加。
        guard !isSettingUpHosting else { return }
        // 当前 button 已挂载内容则无需重复（重复挂载会反复 remove/add 子视图）。
        guard !hostingMounted else { return }
        isSettingUpHosting = true
        Self.activeInstance = self
        guard let button = statusItem.button else {
            // button 尚未就绪（LSUIElement 启动阶段偶发）：下一轮 run loop 再试，最多 60 次。
        setupRetries += 1
        if setupRetries < 60 {
            Log.warning("[statusbar] button 尚未就绪，重试 #\(setupRetries)")
            DispatchQueue.main.async { [weak self] in
                self?.setupPersistentHostingView()
            }
        } else {
            Log.error("[statusbar] button 持续为 nil，状态项无法挂载内容")
            isSettingUpHosting = false
        }
        return
    }
        setupRetries = 0
        Log.info("[statusbar] button 就绪，挂载内容视图")

        let rootView = StatusBarContentView(viewModel: viewModel) { [weak self] width in
            self?.applyStatusItemWidth(width)
        }
        .allowsHitTesting(false)
        let hostingView = NSHostingView(rootView: rootView)

        button.subviews.forEach { $0.removeFromSuperview() }
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -1),
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 0),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 0),
        ])

        // 关键修复：挂载完成后解除 `isSettingUpHosting` 锁，允许以后（重新显示图标时）
        // 再次进入本函数、把内容挂到可能已换新的 button 上；并标记已挂载。
        hostingMounted = true
        isSettingUpHosting = false
    }

    /// 状态栏长度跟随内容自然宽度，尽量贴紧内容避免留白。
    /// 面板打开期间冻结——见 `statusWidthFrozen`。
    private func applyStatusItemWidth(_ contentWidth: CGFloat) {
        guard !statusWidthFrozen else { return }
        // 初次布局前 SwiftUI 可能瞬时回传 0（尚未完成测量）。若此时直接采用，
        // 状态项会塌陷到 20pt 几乎不可见。内容宽度不可信（< 30）时，保留 init 的保底宽度，
        // 等真实宽度到来再接管，彻底杜绝「0 宽 → 状态栏消失」。
        guard contentWidth >= 30 else { return }
        let target = max(20, ceil(contentWidth))
        if abs(statusItem.length - target) > 0.5 {
            statusItem.length = target
        }
    }

    private func startAppearanceObservation() {
        Task { [weak self] in
            for await _ in Defaults.updates(.appearanceMode, initial: false) {
                self?.applyAppearance()
            }
        }
    }

    /// 按「系统监控总开关（主）」+「显示菜单栏图标（次）」共同决定状态项是否出现在菜单栏。
    /// - 主开关关闭：无论次级开关如何，图标强制隐藏（体现「主-次」层级）。
    /// - 主开 + 次开：状态项出现；若内容尚未挂载（首次或曾被隐藏），重新挂载。
    private func applyIconVisibility() {
        let visible = isMonitorEnabled() && Defaults[.statusBarIconVisible]
        statusItem.isVisible = visible
        if visible {
            // 重新显示时 button 可能是系统新创建的实例（隐藏状态项会释放旧 button），
            // 必须清掉挂载标记并重新挂载内容，否则图标回来却空无一物（旧 bug）。
            hostingMounted = false
            setupPersistentHostingView()
        } else {
            // 隐藏会释放 button，标记内容已失效，下次显示时强制重挂。
            hostingMounted = false
        }
    }

    /// 监听「显示菜单栏图标」开关，运行中切换即时生效，无需重启。
    private func startIconVisibilityObservation() {
        Task { [weak self] in
            for await _ in Defaults.updates(.statusBarIconVisible, initial: false) {
                self?.applyIconVisibility()
            }
        }
    }

    /// 监听「系统监控」总开关：monitor 关闭时图标强制隐藏，重新开启时按次级开关恢复显示。
    private func startMonitorEnabledObservation() {
        monitorEnabledObserver = NotificationCenter.default.addObserver(
            forName: .featureEnabledChanged, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard (note.userInfo?["id"] as? String) == "monitor" else { return }
                self.applyIconVisibility()
            }
        }
    }

    private func applyAppearance() {
        let appearance = Defaults[.appearanceMode].nsAppearance
        // 同步应用级外观，确保设置窗口等「软件本身」也跟随日间 / 夜间 / 跟随系统。
        NSApplication.shared.appearance = appearance
        panel?.appearance = appearance
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if isPanelVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    deinit {
    }
}

/// 状态栏下拉面板。无边框 + 非激活，但必须能成为 key 窗口，
/// 否则里面的按钮 / 滚动条收不到点击。
private final class DashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct StatusBarContentView: View {
    let viewModel: MenuViewModel
    var onWidth: ((CGFloat) -> Void)? = nil

    // 按 11pt Times New Roman 实测字符宽度，把固定框缩到最小，避免数字位数变化导致整体左右摆动。
    // 功率最多显示 99.99、电量百分比最多 100，按各自最大值测量即可保证不裁切。
    private static let statusFont = NSFont(name: "Times New Roman", size: 11)
        ?? NSFont.systemFont(ofSize: 11)
    private static let powerNumberWidth = ceil(
        ("99.99" as NSString).size(withAttributes: [.font: statusFont]).width) + 0
    private static let percentNumberWidth = ceil(
        ("100" as NSString).size(withAttributes: [.font: statusFont]).width) + 0
    private static let unitWWidth = ceil(
        ("W" as NSString).size(withAttributes: [.font: statusFont]).width) + 1
    private static let unitPctWidth = ceil(
        ("%" as NSString).size(withAttributes: [.font: statusFont]).width) + 1
    // 系统状态 6 项在状态栏中显示所需的固定宽度（11pt Times New Roman）。
    private static let threeDigitNumberWidth = ceil(
        ("100" as NSString).size(withAttributes: [.font: statusFont]).width) + 0
    private static let fourDigitNumberWidth = ceil(
        ("9999" as NSString).size(withAttributes: [.font: statusFont]).width) + 0
    private static let decimalNumberWidth = ceil(
        ("999.9" as NSString).size(withAttributes: [.font: statusFont]).width) + 0
    private static let unitGWidth = ceil(
        ("G" as NSString).size(withAttributes: [.font: statusFont]).width) + 1
    private static let unitCWidth = ceil(
        ("°C" as NSString).size(withAttributes: [.font: statusFont]).width) + 1
    // 网速模块 9pt 字体（状态栏高度有限，比 11pt 其他模块小一号）。
    private static let statusFont9 = NSFont(name: "Times New Roman", size: 9)
        ?? NSFont.systemFont(ofSize: 9)
    // 网速整体模块固定宽度：按用户要求，每行至少完整显示 ▲ + 三个数字 + 一个小数点 + 单位，
    // 即 ▲999.9M；同时兼容 ▲9999K。取两者较宽者并留 4pt 余量，避免状态栏裁剪。
    private static let networkModuleWidth = ceil(
        max(
            ("▲9999K" as NSString).size(withAttributes: [.font: statusFont9]).width,
            ("▲999.9M" as NSString).size(withAttributes: [.font: statusFont9]).width
        )) + 4

    @State private var moduleOrder: [StatusBarModule] = Defaults[.statusBarModuleOrder]
    @State private var hiddenModules: [StatusBarModule] = Defaults[.statusBarHiddenModules]
    @State private var percentageDisplayLocation: PercentageDisplayLocation = Defaults[.batteryPercentageDisplayLocation]
    @State private var showState: Bool = Defaults[.showBatteryStateInStatusIcon]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(visibleModules, id: \.self) { module in
                moduleContent(module)
            }
        }
        .fixedSize()
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: StatusBarWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(StatusBarWidthKey.self) { width in
            onWidth?(width)
        }
        // 状态栏视图挂在 NSHostingView 上，@Default 的订阅不一定能驱动重绘，
        // 这里用 onReceive 显式把 Defaults 变更桥接到 @State，确保排序/隐藏/显示位置实时生效。
        .onReceive(Defaults.publisher(.statusBarModuleOrder)) { moduleOrder = $0.newValue }
        .onReceive(Defaults.publisher(.statusBarHiddenModules)) { hiddenModules = $0.newValue }
        .onReceive(Defaults.publisher(.batteryPercentageDisplayLocation)) { percentageDisplayLocation = $0.newValue }
        .onReceive(Defaults.publisher(.showBatteryStateInStatusIcon)) { showState = $0.newValue }
    }

    private var visibleModules: [StatusBarModule] {
        let hidden = Set(hiddenModules)
        return moduleOrder.filter { !hidden.contains($0) }
    }

    @ViewBuilder
    private func moduleContent(_ module: StatusBarModule) -> some View {
        switch module {
        case .batteryIcon:
            BatteryIndicatorView(
                batteryLevel: viewModel.displayPercentage,
                chargingMode: viewModel.chargingMode,
                isLowPowerModeEnabled: viewModel.isLowPowerModeEnabled,
                percentageDisplayLocation: percentageDisplayLocation,
                showState: showState
            )
        case .batteryPercentage:
            // 数字框按实测宽度固定右对齐，百分号位置固定，数字位数变化不导致整体左右摆动。
            HStack(spacing: 0) {
                Text("\(viewModel.displayPercentage)")
                    .frame(width: Self.percentNumberWidth, alignment: .trailing)
                Text("%")
                    .frame(width: Self.unitPctWidth, alignment: .leading)
            }
            .font(.custom("Times New Roman", size: 11))
            .foregroundStyle(percentageColor)
        case .systemPower:
            // 数值框按实测宽度固定右对齐，"W" 位置固定，功率数值变化时图标不随之左右移动。
            HStack(spacing: 0) {
                Text(String(format: "%.2f", abs(viewModel.systemPower)))
                    .frame(width: Self.powerNumberWidth, alignment: .trailing)
                Text("W")
                    .frame(width: Self.unitWWidth, alignment: .leading)
            }
            .font(.custom("Times New Roman", size: 11))
            .padding(.leading, 1)

        // MARK: 系统状态 6 项
        case .cpuTemp:
            HStack(spacing: 0) {
                Text(cpuTempText)
                    .frame(width: Self.threeDigitNumberWidth, alignment: .trailing)
                Text("°C")
                    .frame(width: Self.unitCWidth, alignment: .leading)
            }
            .font(.custom("Times New Roman", size: 11))
        case .cpu:
            HStack(spacing: 0) {
                Text(cpuUsageText)
                    .frame(width: Self.threeDigitNumberWidth, alignment: .trailing)
                Text("%")
                    .frame(width: Self.unitPctWidth, alignment: .leading)
            }
            .font(.custom("Times New Roman", size: 11))
        case .memory:
            HStack(spacing: 0) {
                Text(memoryText)
                    .frame(width: Self.decimalNumberWidth, alignment: .trailing)
                Text("G")
                    .frame(width: Self.unitGWidth, alignment: .leading)
            }
            .font(.custom("Times New Roman", size: 11))
        case .disk:
            HStack(spacing: 0) {
                Text(diskText)
                    .frame(width: Self.fourDigitNumberWidth, alignment: .trailing)
                Text("G")
                    .frame(width: Self.unitGWidth, alignment: .leading)
            }
            .font(.custom("Times New Roman", size: 11))
        case .fan:
            Text(fanText)
                .frame(width: Self.fourDigitNumberWidth, alignment: .trailing)
                .font(.custom("Times New Roman", size: 11))
        case .network:
            // 上下行垂直排列，9pt 适配状态栏高度；整体模块宽度固定，
            // 箭头在模块内固定靠左，数字/单位紧跟其后，避免与左侧模块贴太近。
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("▲")
                    Text(networkNumber(viewModel.networkUpMBps))
                    Text(networkUnit(viewModel.networkUpMBps))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    Text("▼")
                    Text(networkNumber(viewModel.networkDownMBps))
                    Text(networkUnit(viewModel.networkDownMBps))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.custom("Times New Roman", size: 9))
            .padding(.leading, 3)
            .frame(width: Self.networkModuleWidth, alignment: .leading)
        }
    }

    private var cpuTempText: String {
        viewModel.cpuTemperatureC >= 0 ? "\(Int(viewModel.cpuTemperatureC))" : "—"
    }

    private var cpuUsageText: String {
        viewModel.cpuUsagePercent >= 0 ? "\(Int(viewModel.cpuUsagePercent))" : "—"
    }

    private var memoryText: String {
        viewModel.memoryUsedGB >= 0 ? String(format: "%.1f", viewModel.memoryUsedGB) : "—"
    }

    private var diskText: String {
        viewModel.diskFreeGB >= 0 ? "\(Int(viewModel.diskFreeGB))" : "—"
    }

    private var fanText: String {
        viewModel.fanRPM >= 0 ? "\(Int(viewModel.fanRPM))" : "—"
    }

    private func networkNumber(_ mbps: Double) -> String {
        if mbps < 0 { return "—" }
        if mbps < 1 { return "\(Int(mbps * 1000))" }
        return String(format: "%.1f", mbps)
    }

    private func networkUnit(_ mbps: Double) -> String {
        if mbps < 0 { return "" }
        return mbps < 1 ? "K" : "M"
    }

    private var percentageColor: Color {
        guard showState else { return .primary }
        if viewModel.displayPercentage <= 20 { return .red }
        return .primary
    }
}

private struct StatusBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
