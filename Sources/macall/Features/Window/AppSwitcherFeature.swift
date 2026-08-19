import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// One window entry shown in the AltTab-style switcher.
struct SwitcherItem: Identifiable {
    let id: CGWindowID
    let owner: String
    let title: String
    let pid: pid_t
    let image: NSImage?
    /// Window thumbnail aspect ratio (width / height). Drives the card width so
    /// each tile keeps the real window's proportions (not forced to equal width).
    let aspect: CGFloat
    /// Direct AX reference so we can act on the window even when it is minimized
    /// (off-screen, hence has no usable CGWindowID/thumbnail). Lets the switcher
    /// restore minimized windows — a plain "hide" could not be brought back.
    let axWindow: AXUIElement?
    /// The owning app's icon — used as the placeholder for windows without a
    /// thumbnail, and as the tile itself in icon mode (all windows minimized).
    let appIcon: NSImage?
    /// Whether this entry is a live on-screen thumbnail, a minimized window
    /// (captured live or replayed), or a hidden (⌘H) app (replayed cache only).
    let state: WindowState
}

/// AltTab 风格窗口切换器：Windows / macOS 式「按住循环」行为：
///
///  - 触发快捷键（如 ⌘⌥Tab）→ 面板**居中**打开，所有缩略图等高但**宽度可变**
///    （匹配每个窗口的真实宽高比）。每个 App 的每个窗口单独成块（非 tab）。
///  - **最前台 App 的窗口**被预选中。
///  - 再次按下快捷键（或 ← / ↑ / → / ↓）移动选择。
///  - 每个块左上角有**关闭（红）/ 最小化（黄）/ 最大化（绿）**按钮，macOS
///    红绿灯样式。
///  - **Enter / Space / 点击**激活高亮窗口并关闭面板。
///  - 松开触发修饰键（如 ⌘）打开高亮窗口，与原生行为一致。面板打开期间还可：
///      • **Q** 强制退出选中 App
///      • **W** 关闭选中窗口（App 继续运行）
///      • **H** 最小化选中窗口
///      • **M** 最大化选中窗口
///      • **Esc** 取消
///
/// 移植自 Macindow 的 AppSwitcherFeature（MIT），仅把配置开关改为 macall 的
/// `enabledFeatures` 通用模型。TrafficButton 与 macClose/macMinimize/macMaximize
/// 颜色已存在于本项目 UI/TrafficButton.swift，此处不再重复定义。
final class AppSwitcherFeature: Feature {
    let id = "switcher"
    let title = IadenteL10n.t("窗口切换", "Window Switcher")
    let category = FeatureCategory.window

    private var panel: NSPanel?
    private var context: AppContext?
    private var enabled = true
    private var items: [SwitcherItem] = []
    private var selected = 0
    private var model: [SwitcherRowModel] = []
    /// 没有任何窗口有实时缩略图时为 true（例如刚全部最小化）。此时切换器回退到
    /// 系统式**App 图标网格**：每个 App 一个块，点击恢复 + 激活。
    private var iconMode = false
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var clickMonitor: Any?
    /// 打开面板的修饰键——松开它们即提交高亮选择（镜像系统 ⌘-Tab 行为）。
    private var triggerMods: NSEvent.ModifierFlags = []
    /// 为 true 时，下一次 `commit()`（如松开触发修饰键）应仅关闭面板**而不**
    /// 激活任何窗口。破坏性操作（最小化/关闭/退出）后设置，以免松开 ⌘ 又激活
    /// 并取消我们刚缩小的窗口。
    private var suppressCommit = false

    // MARK: - 布局常量

    private let hPad: CGFloat = 22   // 水平内边距（左右）
    private let vPad: CGFloat = 32   // 垂直内边距（上下）——更宽松
    private let gap: CGFloat = 16
    private let cardH: CGFloat = 176 // 固定 → 所有缩略图等高
    private let minCardW: CGFloat = 96
    private let maxCardW: CGFloat = 360
    private let iconTileW: CGFloat = 116  // 图标模式近似方形块
    private let iconTileH: CGFloat = 128
    /// 渲染底部快捷键图例所需的最小内宽。低于此值完全隐藏图例，避免小面板裁切。
    private let legendMinContentW: CGFloat = 400

    /// 当前显示模式的行高。
    private var rowH: CGFloat { iconMode ? iconTileH : cardH }

    /// 待定的延迟重建（见 `scheduleRebuild`）。
    private var rebuildWorkItem: DispatchWorkItem?

    // MARK: - Feature

    func install(context: AppContext) {
        self.context = context
        self.enabled = context.config.enabledFeatures["switcher"] ?? true
        let combo = context.config.hotkeys["switcher.show"]?.toCombo()
            ?? Configuration.defaultHotkeys()["switcher.show"]!.toCombo()
        triggerMods = NSEvent.ModifierFlags(rawValue: UInt(combo.flags))
        context.hotkeys.bind(featureId: id, action: "show", configKey: "switcher.show", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "show" {
            if panel == nil { open() } else { move(1) }
        }
    }

    func reload(config: Configuration) {
        enabled = config.enabledFeatures["switcher"] ?? true
        let combo = config.hotkeys["switcher.show"]?.toCombo()
            ?? Configuration.defaultHotkeys()["switcher.show"]!.toCombo()
        triggerMods = NSEvent.ModifierFlags(rawValue: UInt(combo.flags))
    }
    func uninstall() { close() }
    func reenable() {}
    func ensureTap() {}

    // MARK: - 打开 / 关闭

    private func open() {
        guard enabled, context?.config.enabled ?? true else { return }
        NSApp.activate(ignoringOtherApps: true)
        suppressCommit = false
        items = Self.collect()
        guard !items.isEmpty else {
            Log.info("窗口切换：当前没有可显示的窗口")
            return
        }
        applyDisplayMode()
        selected = Self.defaultIndex(for: items)
        if panel == nil { createPanel() }
        installMonitors()
        refresh()
        Log.info("窗口切换已打开（\(items.count) 个窗口，默认选中 #\(selected)）")
    }

    private func close() {
        rebuildWorkItem?.cancel()
        rebuildWorkItem = nil
        removeMonitors()
        suppressCommit = false
        panel?.orderOut(nil)
        panel = nil
        model = []
    }

    /// 激活当前高亮窗口并关闭面板。
    private func commit() {
        // 用户刚执行了操作（最小化/关闭/退出），面板处于「操作模式」：关闭绝不能
        // 重新激活窗口（那会取消我们刚缩小的窗口）。仅关闭。
        if suppressCommit {
            suppressCommit = false
            close()
            return
        }
        guard items.indices.contains(selected) else { close(); return }
        let it = items[selected]
        if iconMode {
            // 图标块 = 整个 App：恢复其所有最小化窗口。
            if let app = NSRunningApplication(processIdentifier: it.pid) {
                if let wins = AX.windows(of: app) {
                    for w in wins where AX.isMinimized(w) { AX.setMinimized(w, false) }
                }
                app.activate(options: .activateIgnoringOtherApps)
            }
            Log.info("窗口切换(图标模式) -> 恢复并激活 \(it.owner)")
            close()
            return
        }
        if let win = it.axWindow {
            AX.setMinimized(win, false)   // 若已最小化则恢复
        }
        if it.state == .hidden,
           let app = NSRunningApplication(processIdentifier: it.pid), app.isHidden {
            app.unhide()   // ⌘H 隐藏 -> 带回
        }
        let vsItem = VSSwitcherItem.window(id: it.id, title: it.title, appName: it.owner,
                                           pid: it.pid, isOnScreen: it.state == .live,
                                           isMinimized: it.state == .minimized, frame: .zero)
        VSWindowActivator.activate(vsItem, retry: true)
        Log.info("窗口切换 -> \(it.owner) / \(it.title)")
        close()
    }

    /// 在缩略图模式与系统式图标模式间抉择。当没有任何条目有实时预览时（例如刚
    // 「全部最小化」）进入图标模式。每个 App 一个块，类似 ⌘Tab。
    private func applyDisplayMode() {
        iconMode = !items.isEmpty && items.allSatisfy { $0.image == nil }
        if iconMode { items = Self.dedupeByApp(items) }
    }

    /// 重新收集、重算布局、重渲面板。
    private func refresh() {
        guard let panel = panel else { return }
        model = computeRows()
        let (w, h, showLegend) = panelSize()
        let view = SwitcherView(
            rows: model,
            selectedIndex: selected,
            vPad: vPad,
            hPad: hPad,
            gap: gap,
            cardH: rowH,
            iconMode: iconMode,
            showLegend: showLegend,
            onPick: { [weak self] idx in
                self?.selected = idx
                self?.commit()
            },
            onClose: { [weak self] idx in self?.onClose(idx: idx) },
            onMinimize: { [weak self] idx in self?.onMinimize(idx: idx) },
            onMaximize: { [weak self] idx in self?.onMaximize(idx: idx) }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let x = screen.frame.midX - w / 2
        let y = screen.frame.midY - h / 2
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// 每个窗口操作：关闭该窗口；若它是 App 最后一个可见窗口，则强制退出整个 App。
    private func onClose(idx: Int) {
        guard items.indices.contains(idx) else { return }
        let it = items[idx]

        // 图标模式：块就是 App -> 强制退出整个 App。
        if iconMode {
            if let app = NSRunningApplication(processIdentifier: it.pid) {
                app.forceTerminate()
                Log.info("图标模式强制退出: \(it.owner)")
            }
            removeCards { $0.pid == it.pid }   // 乐观：立即移除
            suppressCommit = true
            scheduleRebuild()                  // 然后与现实重新同步
            return
        }

        guard let win = it.axWindow else { return }

        // 检查该 App 除本窗口外是否还有其它窗口。
        let appHasOtherWindows = items.contains { $0.pid == it.pid && $0.id != it.id }

        if appHasOtherWindows {
            // 仅关闭这一个窗口；其余保留。
            AX.closeWindow(win)
            removeCards { $0.id == it.id && $0.pid == it.pid }
        } else {
            // 最后一个窗口 -> 强制退出整个 App。
            AX.closeWindow(win)
            if let app = NSRunningApplication(processIdentifier: it.pid) {
                app.forceTerminate()
                Log.info("强制退出: \(it.owner)")
            }
            removeCards { $0.pid == it.pid }
        }
        suppressCommit = true
        scheduleRebuild()
    }

    /// 乐观地从当前列表移除匹配块并立即重渲——关闭/退出是异步的，立即重新收集
    /// 仍会看到将死的窗口而留下陈旧预览。
    private func removeCards(where match: (SwitcherItem) -> Bool) {
        items.removeAll(where: match)
        if items.isEmpty { close(); return }
        applyDisplayMode()
        selected = min(selected, items.count - 1)
        refresh()
    }

    /// 在 App/窗口真正死亡后重新收集，使列表与现实收敛（也处理「关闭被 App 取消」）。
    private func scheduleRebuild(after delay: TimeInterval = 0.8) {
        rebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel != nil else { return }
            self.rebuildAfterAction()
        }
        rebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 每个窗口操作：最小化。
    private func onMinimize(idx: Int) {
        guard items.indices.contains(idx) else { return }
        let it = items[idx]
        if let win = it.axWindow { AX.minimizeWindow(win) }
        // 乐观地立即丢弃该块。否则当用户松开触发修饰键（如 ⌘）时，flagsChanged
        // 监听触发 `commit()`，会激活此 App 并*取消*我们刚缩小的窗口——「缩小又
        // 弹回」的 bug。
        removeCards { $0.id == it.id && $0.pid == it.pid }
        suppressCommit = true   // 松开时关闭而非重新激活
        scheduleRebuild()
    }

    /// 每个窗口操作：最大化 -> 激活并关闭。
    private func onMaximize(idx: Int) {
        guard items.indices.contains(idx) else { return }
        let it = items[idx]
        if let win = it.axWindow {
            AX.maximizeWindow(win)
            if let app = NSRunningApplication(processIdentifier: it.pid) {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
        suppressCommit = true
        close()
    }

    // MARK: - 键盘操作（Tab 触发，然后 Q / W / M / F）

    /// Q — 不先激活就强制退出选中 App。用于冻结或拒绝正常退出的 App。
    private func forceQuitSelected() {
        guard items.indices.contains(selected) else { return }
        let it = items[selected]
        guard it.pid != ProcessInfo.processInfo.processIdentifier else { return }
        if let app = NSRunningApplication(processIdentifier: it.pid) {
            app.forceTerminate()
            Log.info("窗口切换快捷键：强制退出 \(it.owner)")
        }
        removeCards { $0.pid == it.pid }
        suppressCommit = true
        scheduleRebuild()
    }

    /// W — 关闭选中**窗口**而不终止 App。这正是红色红绿灯：进程继续运行（可能
    /// 后台运行，或用其它窗口）。我们绝不调用 `terminate()`——只用 `AX.closeWindow`，
    /// 所以 App 永不被杀。
    private func closeWindowSelected() {
        guard items.indices.contains(selected) else { return }
        let it = items[selected]
        guard let win = it.axWindow else {
            // 无 AX 窗口句柄（如隐藏 App 的图标块）-> 无可关闭。
            return
        }
        AX.closeWindow(win)
        removeCards { $0.id == it.id && $0.pid == it.pid }
        suppressCommit = true
        scheduleRebuild()
    }

    /// H — 最小化选中窗口（同黄色红绿灯）。
    private func minimizeSelected() { onMinimize(idx: selected) }

    /// M — 最大化选中窗口到其屏幕可见区域。
    private func maximizeSelected() { onMaximize(idx: selected) }

    /// 破坏性操作（关闭/最小化）后重新收集窗口列表并刷新（无则完全关闭）。
    private func rebuildAfterAction() {
        items = Self.collect()
        if items.isEmpty { close(); return }
        applyDisplayMode()
        selected = min(selected, items.count - 1)
        refresh()
    }

    // MARK: - 面板创建

    private func createPanel() {
        let p = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        panel = p
    }

    // MARK: - 布局计算

    /// 同时用于换行和最大帧宽。
    private var maxContentW: CGFloat {
        min(1180.0, (NSScreen.main?.frame.width ?? 1440) * 0.92)
    }

    /// 构建变宽卡片的平衡行（贪心换行）。
    private func computeRows() -> [SwitcherRowModel] {
        let maxW = maxContentW
        var rows: [SwitcherRowModel] = []
        var current: [SwitcherCardModel] = []
        var rowW: CGFloat = 0

        for (idx, item) in items.enumerated() {
            let w = cardWidth(for: item.aspect)
            if !current.isEmpty, rowW + gap + w > maxW {
                rows.append(SwitcherRowModel(cards: current))
                current = []
                rowW = 0
            }
            current.append(SwitcherCardModel(id: idx, item: item, width: w, index: idx))
            rowW += (current.count == 1 ? 0 : gap) + w
        }
        if !current.isEmpty { rows.append(SwitcherRowModel(cards: current)) }
        return rows
    }

    /// 由窗口宽高比派生的卡片宽度，限制在合理范围内。
    private func cardWidth(for aspect: CGFloat) -> CGFloat {
        if iconMode { return iconTileW }
        let w = cardH * aspect
        return min(max(w, minCardW), maxCardW)
    }

    /// 从当前行得到的总面板尺寸（对称内边距，自动适配宽度）。
    /// 同时返回图例可见性标志：仅当面板足够宽以完整显示时显示底部提示行。
    private func panelSize() -> (CGFloat, CGFloat, Bool) {
        let rows = max(model.count, 1)
        // 宽度 = 最宽行的实际内容宽（使单个窗口紧密贴合）。
        var widest: CGFloat = 0
        for r in model {
            var w: CGFloat = 0
            for (i, c) in r.cards.enumerated() {
                w += (i == 0 ? 0 : gap) + c.width
            }
            widest = max(widest, w)
        }
        let contentW = min(widest, maxContentW)
        let showLegend = contentW >= legendMinContentW
        let legendH: CGFloat = 22
        let legendGap: CGFloat = showLegend ? gap : 0
        let contentH = CGFloat(rows) * rowH + CGFloat(rows - 1) * gap + legendGap + (showLegend ? legendH : 0)
        let w = contentW + hPad * 2
        let h = contentH + vPad * 2
        return (w, h, showLegend)
    }

    private func move(_ dir: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + dir + items.count) % items.count
        refresh()
    }

    // MARK: - 监听

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self, self.panel != nil else { return ev }
            switch ev.keyCode {
            case 53: self.close(); return nil                              // Esc → 取消
            case 36, 76, 49: self.commit(); return nil                    // Enter / Return / Space → 切换
            case 48: self.move(1); return nil                             // Tab → 下一个
            case 123, 126: self.move(-1); return nil                      // ← / ↑
            case 124, 125: self.move(1); return nil                       // → / ↓
            case 12: self.forceQuitSelected(); return nil                 // Q → 强制退出选中 App
            case 13: self.closeWindowSelected(); return nil              // W → 关闭选中窗口（不退出程序）
            case 4:  self.minimizeSelected(); return nil                 // H → 最小化选中窗口
            case 46: self.maximizeSelected(); return nil                 // M → 全屏/最大化选中窗口
            default: return ev
            }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            guard let self = self, self.panel != nil else { return ev }
            // 松开触发修饰键（如 ⌘）打开高亮窗口——同原生行为。Q/W 可在按住修饰键
            // 时轻点。
            if !ev.modifierFlags.contains(self.triggerMods) {
                self.commit()
            }
            return ev
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }
            let loc = NSEvent.mouseLocation
            if !panel.frame.contains(loc) {
                self.commit()
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: - 收集

    /// 收集切换器中值得显示的每个窗口：屏幕上的窗口（真实实时缩略图）PLUS 最小化
    /// 窗口（现在可实时捕获，或回放缓存）。包含最小化窗口意味着切换器可把它们带
    /// 回——纯「隐藏」会让它们不可达。
    ///
    /// 每个条目以其**真实 CGWindowID** 为键（现已通过 `_AXUIElementGetWindow`
    /// 可靠解析），绝不以 App 为键。这正是消除跨窗口 / 跨 App「错误预览」bug 的根
    /// 本：多窗口 App 显示每个窗口自己的 frame，而非共享一个 frame。
    /// 通过 vorssaint 的窗口服务路径（`CGSHWCaptureWindowList`）捕获窗口缩略图
    /// 并应用其结构校验：Stage-Manager 倾斜条状图稿和窗口服务裁剪切片被拒绝，因此
    /// 切换器回退到 App 图标而非显示破损预览。同步（与旧 `PreviewCapture` 调用相同
    /// 契约），因此面板仍以即时缩略图打开。
    private static func vsThumbnail(windowID: CGWindowID?, pid: pid_t, frame: CGRect, isMinimized: Bool) -> NSImage? {
        guard let wid = windowID, wid != 0 else { return nil }
        guard let img = VSCaptureBridge.thumbnail(windowID: wid,
                                                  windowSize: frame.size,
                                                  isMinimized: isMinimized,
                                                  maxDim: 720) else { return nil }
        return img
    }

    static func collect() -> [SwitcherItem] {
        var out: [SwitcherItem] = []

        // 1) 屏幕上窗口（真实实时缩略图，每个窗口一个块）。
        //    共享的 `WindowList` 枚举器执行 CoreGraphics 扫描 + Accessibility
        //    幽灵否决（之前内联在此处），并从所有者名解析每个窗口的捕获策略
        //    （因此 Chrome 辅助进程拥有的窗口仍获得隐藏 URL 栏的浏览器裁剪）。
        //    `expectedSize` 馈入结构覆盖校验，拒绝裁剪捕获。
        for pw in WindowList.onScreenWindows() {
            let pidT = pw.pid
            let runningApp = NSRunningApplication(processIdentifier: pidT)
            let image = Self.vsThumbnail(windowID: pw.id, pid: pidT, frame: pw.frame, isMinimized: false)
            let aspect: CGFloat = {
                guard let img = image, img.size.height > 0 else { return 1.6 }
                return min(max(img.size.width / img.size.height, 0.28), 3.5)
            }()
            let ax = AX.windowWithID(pw.id)                     // 精确反向查找
            let icon = runningApp?.icon
            if let image {
                // 为 ⌘H 隐藏回退持久化 App 级前置 frame；每窗口 frame 已存在于
                // WindowPreviewProvider 的 LRU 缓存（经 VSCaptureBridge），因此
                // 不再在此重复。
                ThumbnailCache.store(pid: pidT, title: pw.title, image: image)
            }
            out.append(SwitcherItem(id: pw.id, owner: pw.ownerName, title: pw.title, pid: pidT,
                                   image: image, aspect: aspect, axWindow: ax, appIcon: icon,
                                   state: .live))
        }

        // 2) 最小化窗口。现在可通过 WindowServer 实时捕获（CGSHWCaptureWindowList
        //    读取保留的后备存储，可 survives minimize），因此它们不再需要回放陈旧
        //    frame，也不再降级为裸 App 图标。我们严格以真实窗口 id 为键，使多窗口
        //    App 显示每个窗口自己的 frame——旧 `lookupFront(app)` 以 App 为键的
        //    查找是「⌘Tab 显示错误窗口」bug 的根源，现在仅作最后回退。
        let seen = Set(out.compactMap { $0.id == 0 ? nil : $0.id })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            for win in AX.actualWindows(of: app) where AX.isMinimized(win) {
                let wid = AX.cgWindowID(of: win)
                if let wid, wid != 0, seen.contains(wid) { continue }

                // 最小化窗口可对原生/浏览器 App 实时捕获（WindowServer 保留后备
                // 存储），但最小化的*Web* App 捕获为空白矩形——因此每种情况都经
                // 单一解析器，仅在确实有效时实时捕获，否则回放缓存 / 回退到 App 图标。
                // 绝不会返回空白 frame。
                let image = Self.vsThumbnail(windowID: wid, pid: app.processIdentifier, frame: .zero, isMinimized: true)
                let resolvedTitle = AX.title(of: win) ?? ThumbnailCache.lookupFront(of: app)?.title ?? ""

                let aspect: CGFloat = {
                    guard let img = image, img.size.height > 0 else { return 1.6 }
                    return min(max(img.size.width / img.size.height, 0.28), 3.5)
                }()
                out.append(SwitcherItem(id: wid ?? 0, owner: app.localizedName ?? "",
                                        title: resolvedTitle, pid: app.processIdentifier,
                                        image: image, aspect: aspect, axWindow: win,
                                        appIcon: app.icon, state: .minimized))
            }
        }

        // 3) 隐藏（⌘H）的 App——未合成，因此实时捕获不可能。每个 App 一个块（镜像
        //    系统 ⌘Tab），使用前置窗口的最后缓存 frame。这是唯一 App 级查找作为
        //    预期回退的地方，因为隐藏 App 的 AX 枚举不返回任何内容，我们确实无法
        //    识别单个窗口。
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.isHidden {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            let win = AX.windows(of: app)?.first
            let cached = ThumbnailCache.lookupFront(of: app)
            let title = cached?.title ?? win.flatMap { AX.title(of: $0) } ?? ""
            let image = cached?.image
            let aspect: CGFloat = {
                guard let img = image, img.size.height > 0 else { return 1.6 }
                return min(max(img.size.width / img.size.height, 0.28), 3.5)
            }()
            out.append(SwitcherItem(id: 0, owner: app.localizedName ?? "",
                                    title: title, pid: app.processIdentifier,
                                    image: image, aspect: aspect, axWindow: win,
                                    appIcon: app.icon, state: .hidden))
        }
        return out
    }

    /// 每个 App 一个条目（第一个赢）——图标模式使用，镜像系统 ⌘Tab 每个 App 一个图标。
    static func dedupeByApp(_ items: [SwitcherItem]) -> [SwitcherItem] {
        var seen = Set<pid_t>()
        var out: [SwitcherItem] = []
        for it in items where !seen.contains(it.pid) {
            seen.insert(it.pid)
            out.append(it)
        }
        return out
    }

    /// 最前台 App 的窗口索引，否则 0 作为回退。
    static func defaultIndex(for items: [SwitcherItem]) -> Int {
        guard let front = NSWorkspace.shared.frontmostApplication else { return 0 }
        if let idx = items.firstIndex(where: { $0.pid == front.processIdentifier }) {
            return idx
        }
        return 0
    }
}

// MARK: - 可接收键盘的面板（使内部 SwiftUI 按钮可点击）

private class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 布局模型（与 SwiftUI 视图共享）

struct SwitcherCardModel: Identifiable {
    /// 每个块必须唯一。CGWindowID 不能在此使用：最小化窗口常无可用窗口 ID（0），
    /// 重复 ForEach id 会使 SwiftUI 把所有块渲染为第一个块的内容——那会在所有
    /// 图标模式块上显示相同 App 图标/名称。
    let id: Int
    let item: SwitcherItem
    let width: CGFloat
    let index: Int
}

struct SwitcherRowModel: Identifiable {
    let id = UUID()
    let cards: [SwitcherCardModel]
}

// MARK: - 切换器面板的 SwiftUI 内容

struct SwitcherView: View {
    let rows: [SwitcherRowModel]
    let selectedIndex: Int
    let vPad: CGFloat
    let hPad: CGFloat
    let gap: CGFloat
    let cardH: CGFloat
    let iconMode: Bool
    /// 是否渲染底部快捷键提示行（小面板上隐藏）。
    let showLegend: Bool

    let onPick: (Int) -> Void
    let onClose: (Int) -> Void
    let onMinimize: (Int) -> Void
    let onMaximize: (Int) -> Void

    var body: some View {
        VStack(spacing: gap) {
            ForEach(rows) { row in
                HStack(spacing: gap) {
                    Spacer(minLength: 0)
                    ForEach(row.cards) { card in
                        CardView(
                            card: card,
                            selected: card.index == selectedIndex,
                            cardH: cardH,
                            iconMode: iconMode,
                            onPick: { onPick(card.index) },
                            onClose: { onClose(card.index) },
                            onMin: { onMinimize(card.index) },
                            onMax: { onMaximize(card.index) }
                        )
                        .frame(width: card.width, height: cardH)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: cardH)
                .clipped()
            }

            if showLegend { legend }
        }
        .padding(EdgeInsets(top: vPad, leading: hPad, bottom: vPad, trailing: hPad))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(.ultraThinMaterial)
        .cornerRadius(18)
    }

    /// 面板底部显示的快捷键图例，使 Q/W 键无需打开设置即可发现。
    private var legend: some View {
        HStack(spacing: 12) {
            legendChip("←→↑↓ / Tab", IadenteL10n.t("选择", "Select"))
            legendChip("↩", IadenteL10n.t("切换", "Switch"))
            legendChip("Q", IadenteL10n.t("强退", "Force Quit"))
            legendChip("W", IadenteL10n.t("关闭", "Close"))
            legendChip("H", IadenteL10n.t("缩小", "Minimize"))
            legendChip("M", IadenteL10n.t("全屏", "Full Screen"))
            legendChip("esc", IadenteL10n.t("取消", "Cancel"))
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.top, 2)
    }

    private func legendChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).fontWeight(.semibold)
            Text(label)
        }
    }
}

/// 单个窗口块：变宽、等高，左上角带 macOS 式红绿灯窗口控制（关闭/最小化/最大化）。
///
/// **选择高亮**（蓝色填充 + 边框）绘制在*外层*包裹器上，因此永不被卡片固定高度
/// 内容区裁剪。内部缩略图 + 文本锁定到 `cardH` 并裁剪。
struct CardView: View {
    let card: SwitcherCardModel
    let selected: Bool
    let cardH: CGFloat
    let iconMode: Bool
    let onPick: () -> Void
    let onClose: () -> Void
    let onMin: () -> Void
    let onMax: () -> Void
    /// 自动跟随系统浅色/深色外观。
    @Environment(\.colorScheme) private var scheme

    private let textH: CGFloat = 42   // App 名 + 页面标题的锁定高度
    /// 给选择边框的额外空间，使其永不被裁剪。
    private let selInset: CGFloat = 3

    var body: some View {
        if iconMode { iconTile } else { thumbnailCard }
    }

    /// 无实时缩略图时显示的占位说明（图标模式块改用 App 名，因此这只用于缩略图卡）。
    private static func placeholderText(for state: WindowState) -> String {
        switch state {
        case .live:      return IadenteL10n.t("无预览", "No Preview")
        case .minimized: return IadenteL10n.t("已缩小", "Minimized")
        case .hidden:    return IadenteL10n.t("已隐藏", "Hidden")
        }
    }

    // MARK: 系统式 ⌘Tab App 图标块（所有窗口最小化）。

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 12 + selInset)
            .fill(selected ? Color.accentColor.opacity(0.30) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12 + selInset)
                    .stroke(selected ? Color.accentColor : Color.clear,
                            lineWidth: selected ? 2.5 : 0)
            )
            .padding(selInset)
            .overlay(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(MTheme.surface(scheme))
                    VStack(spacing: 6) {
                        if let icon = card.item.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                        } else {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 44))
                                .foregroundColor(.secondary)
                                .frame(width: 64, height: 64)
                        }
                        Text(card.item.owner)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 单个红色按钮：强制退出 App。
                    TrafficButton(color: .macClose, symbol: "xmark", action: onClose)
                        .padding(6)
                        .zIndex(2)
                        .help(IadenteL10n.t("强制退出", "Force Quit"))
                }
                .frame(width: card.width, height: cardH)
                .clipped()
            )
            .contentShape(Rectangle())
            .onTapGesture { onPick() }
    }

    // MARK: 普通缩略图卡。

    private var thumbnailCard: some View {
        // 外层：选择高亮——始终完全可见，永不被裁剪。
        RoundedRectangle(cornerRadius: 12 + selInset)
            .fill(selected ? Color.accentColor.opacity(0.30) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12 + selInset)
                    .stroke(selected ? Color.accentColor : Color.clear,
                            lineWidth: selected ? 2.5 : 0)
            )
            .padding(selInset)

        // 内层：实际卡片内容，锁定到 cardH，裁剪。
        .overlay(
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(MTheme.surface(scheme))

                VStack(alignment: .leading, spacing: 0) {
                    if let img = card.item.image {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .cornerRadius(8)
                    } else {
                        // 无实时缩略图（最小化）-> App 图标占位。
                        RoundedRectangle(cornerRadius: 8)
                            .fill(MTheme.placeholder(scheme))
                            .overlay(
                                VStack(spacing: 4) {
                                    if let icon = card.item.appIcon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 48, height: 48)
                                    }
                                    Text(Self.placeholderText(for: card.item.state))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.item.owner).font(.caption.bold()).lineLimit(1)
                        Text(card.item.title.isEmpty ? IadenteL10n.t("(无标题)", "(Untitled)") : card.item.title)
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                    .frame(height: textH)
                    .padding(.horizontal, 8)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 左上角红绿灯控制。
                HStack(spacing: 7) {
                    TrafficButton(color: .macClose, symbol: "xmark", action: onClose)
                    TrafficButton(color: .macMinimize, symbol: "minus", action: onMin)
                    TrafficButton(color: .macMaximize, symbol: "plus", action: onMax)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Capsule().fill(MTheme.chip(scheme)))
                .padding(9)
                .zIndex(2)
                .help(IadenteL10n.t("关闭 / 最小化 / 最大化", "Close / Minimize / Maximize"))

                // 回放指示：缩略图不是实时窗口——要么在 Dock 中最小化，要么隐藏
                // （⌘H）App 的最后 frame。
                if card.item.state != .live {
                    Text(card.item.state == .hidden ? IadenteL10n.t("已隐藏", "Hidden") : IadenteL10n.t("已缩小", "Minimized"))
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .foregroundColor(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .zIndex(3)
                }
            }
            .frame(width: card.width, height: cardH)
            .clipped()
        )
        .contentShape(Rectangle())
        .onTapGesture { onPick() }
    }
}
