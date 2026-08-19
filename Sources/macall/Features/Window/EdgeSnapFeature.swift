import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI

/// 拖拽到边缘的分屏（边缘吸附分屏）：把窗口拖到屏幕边缘时自动吸附。
///
/// - **左 / 右边缘**：默认直接吸附为你在设置里预设的默认分屏比例（左 / 右各自独立，
///   可选 1/3·1/2·2/3）；若开启「边缘分屏选择器」，则弹出一个竖向三块选择器，
///   每次拖拽时选 1/3·1/2·2/3。
/// - **左上 / 右上角**（小触发区）：直接吸附为对应 1/4 象限，离开即取消（可关闭）。
/// - **顶部中央**：保持原有行为，打开渲染在单个全屏透明覆盖窗口内的选择器（四块）。
///
/// 移植自 Macindow 的 EdgeSnapFeature（MIT），仅把配置开关改为 macall 的
/// `enabledFeatures` 通用模型。
final class EdgeSnapFeature: Feature {
    let id = "edgeSnap"
    var title: String { IadenteL10n.t("边缘吸附分屏", "Edge Snap") }
    let category = FeatureCategory.window

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var context: AppContext?
    private var enabled = true
    /// tap 创建失败只在状态翻转时打一条日志，避免 `ensureAllTaps()` 每次激活都刷屏。
    private var lastTapFailureLogged = false
    /// `Permissions.isAccessibilityWorking()` 每次都要跑一遍 AX 查询，
    /// 放在 leftMouseDown 回调里会拖慢事件 tap（超时会被 macOS 直接禁用）。
    /// 这里缓存 2 秒，权限状态本来也不会秒级变化。
    private var axOKCache = false
    private var axOKCheckedAt = Date.distantPast

    /// 距离屏幕边缘多近触发边缘吸附（仅左右）。
    private let snapMargin: CGFloat = 20

    // MARK: - 选择器几何（全部 CG 全局坐标，仅计算一次）

    private let barW: CGFloat = 520
    private let barH: CGFloat = 100

    /// 选择栏中展示的四个布局块。
    private let barBlocks: [BlockLayout] = [.half, .third, .quad, .vert]

    // MARK: - 拖拽状态

    private var isDragging = false
    private var draggedWindow: AXUIElement?
    private var originalFrame: CGRect?
    private var currentSnapZone: SnapKind?
    private var previewPanel: NSPanel?
    /// 仅在被拖窗口的 frame 真正移动后才为真。在窗口内拖选文本 / 滑块 / 滚动
    /// 不会移动窗口 frame——那种情况绝不能触发吸附。
    private var windowMoved = false
    private var lastMoveGate = Date.distantPast

    // MARK: - 选择器状态（单个全屏覆盖）

    private var selectorActive = false
    private var selectorPanel: NSPanel?       // 单个全屏透明面板
    private var selectorScreen: NSScreen?
    private var barRectCG: CGRect = .zero      // 固定栏 rect（CG 坐标）
    private var blockRectsCG: [(BlockLayout, CGRect)] = []  // 每个块的 rect
    private let selectorModel = SelectorModel()
    private var keepAliveTimer: Timer?

    /// 绝对最高窗口层级——即便在被拖动的窗口之上，选择器栏也永不被遮盖。
    private static let selectorLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.maximumWindow))
    )

    // MARK: - 边缘分屏选择器（4 选项，每块内小方块可选）状态

    private var edgeSelectorActive = false
    private var edgeSelectorSide: EdgeSide = .left
    private var edgeSelectorPanel: NSPanel?
    private var edgeCellsCG: [(SnapKind, CGRect)] = []
    private var edgeOptionRectsCG: [CGRect] = []
    private let edgeSelectorModel = EdgeSelectorModel()
    private var edgeKeepAliveTimer: Timer?

    // MARK: - Feature

    func install(context: AppContext) {
        self.context = context
        self.enabled = context.config.enabledFeatures["edgeSnap"] ?? true
        installTap()
        Log.info("[edgesnap] 已安装（enabled=\(enabled)）")
    }

    func handle(action: String) {}
    func reload(config: Configuration) {
        self.context?.config = config
        enabled = config.enabledFeatures["edgeSnap"] ?? true
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }
    func uninstall() {
        // 彻底移除鼠标监听（不止禁用）：从 run loop 摘除源并使 mach port 失效，
        // 避免「关闭开关后 tap 仍挂在 run loop 上」的残留。重新开启时由 install/reenable 重建。
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        closeSelector()
        closeEdgeSelector()
        hidePreview()
        Log.info("[edgesnap] 已卸载：移除鼠标监听")
    }
    func reenable() {
        if tap == nil { installTap(); return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }
    /// 由 `FeatureRegistry.ensureAllTaps()` 在每次 App 激活时调用：
    /// tap 还没建起来（冷启动时权限未就绪）就重试，已经建好则确认它仍处于启用状态。
    func ensureTap() {
        if tap == nil {
            installTap()
        } else if let t = tap, !CGEvent.tapIsEnabled(tap: t) {
            CGEvent.tapEnable(tap: t, enable: enabled)
            Log.info("[edgesnap] 鼠标监听被系统禁用，已重新启用")
        }
    }

    // MARK: - 事件监听

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(UInt64(1) << UInt64(CGEventType.leftMouseDown.rawValue))
            | CGEventMask(UInt64(1) << UInt64(CGEventType.leftMouseDragged.rawValue))
            | CGEventMask(UInt64(1) << UInt64(CGEventType.leftMouseUp.rawValue))

        let cb: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let f = Unmanaged<EdgeSnapFeature>.fromOpaque(userInfo).takeUnretainedValue()
            // 自愈：macOS 会禁用回调过慢的 tap。
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = f.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passRetained(event)
            }
            return f.handleEvent(type, event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cb,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            if !lastTapFailureLogged {
                lastTapFailureLogged = true
                Log.error("[edgesnap] 无法创建鼠标监听（辅助功能=\(AXIsProcessTrusted())）。"
                    + "授权后无需重启：切回 macall 窗口会自动重试。")
            }
            return
        }
        lastTapFailureLogged = false
        self.tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: enabled)
        Log.info("[edgesnap] 鼠标监听已启动（拖左/右边缘分屏，拖左上/右上角 1/4，拖顶部中央出选择器）enabled=\(enabled)")
    }

    /// 缓存版辅助功能探测：每 2 秒最多真查一次。
    private func accessibilityOK() -> Bool {
        let now = Date()
        if now.timeIntervalSince(axOKCheckedAt) > 2.0 {
            axOKCheckedAt = now
            axOKCache = Permissions.isAccessibilityWorking()
        }
        return axOKCache
    }

    // MARK: - 事件处理

    private func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard enabled, context?.config.enabled ?? true else {
            return Unmanaged.passRetained(event)
        }
        // 拖拽回调跑在 CoreGraphics 事件 tap 内，由 AppKit 的 run loop 包在 @try/@catch 里：
        // 一旦这里抛出 ObjC 异常，会被 run loop 静默吞掉——表现就是「分屏拖拽时崩一下」，
        // 但进程不退出、功能卡死（build 82 的 #94 即是此症状）。用 MACatchException 兜底
        // 捕获并落到 /tmp/macall_exception.log + NSLog，既不让异常拖垮 App，也能在下次
        // 复现时拿到真正的堆栈来定位根因。
        MACatchException {
            switch type {
            case .leftMouseDown:  self.handleMouseDown(event)
            case .leftMouseDragged: self.handleMouseDragged(event)
            case .leftMouseUp:    self.handleMouseUp(event)
            default: break
            }
        }
        return Unmanaged.passRetained(event) // 永不吞掉事件
    }

    // MARK: - 鼠标按下：检测拖拽起点

    private func handleMouseDown(_ event: CGEvent) {
        let cg = event.location
        guard accessibilityOK() else { return }
        closeSelector()
        closeEdgeSelector()

        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        // CGWindowListCopyWindowInfo 返回的窗口是「从前往后」排序，因此第一个
        // layer-0 且包含光标的窗口正好是用户点击的窗口。
        var hitWid: CGWindowID = 0
        var hitBounds: CGRect = .zero
        var hitPID: pid_t = 0
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }
            guard owner != "Dock" && owner != "Window Server" && owner != "macall" else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.width > 40, rect.height > 40, rect.contains(cg) else { continue }
            hitWid = (w[kCGWindowNumber as String] as? UInt32) ?? 0
            hitBounds = rect
            hitPID = (w[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } ?? 0
            break
        }

        guard hitWid != 0 else { return }

        // 解析 AX 窗口：优先按精确 wid；失败则按「位置匹配」回退。AX 列表与 CG
        // 列表存在时序差，windowWithID 偶尔返回 nil——这正是「吸附完全没反应」的
        // 头号嫌疑，回退到按边界匹配可覆盖绝大多数 App。
        var axWin: AXUIElement? = AX.windowWithID(hitWid)
        if axWin == nil, hitPID != 0 {
            if let app = NSRunningApplication(processIdentifier: hitPID),
               let wins = AX.windows(of: app) {
                for w in wins {
                    if let f = AX.frame(of: w),
                       abs(f.origin.x - hitBounds.origin.x) < 30,
                       abs(f.origin.y - hitBounds.origin.y) < 30 {
                        axWin = w
                        break
                    }
                }
            }
        }
        guard let resolved = axWin else { return }

        // 位置交叉校验：坐标系差异（AX 原点左上 / CG 原点左下）曾让 12px 校验
        // 永远不过 —— 改成仅在偏差 >40pt 时才视为疑似错窗而放弃。
        if let f = AX.frame(of: resolved) {
            let dx = abs(f.origin.x - hitBounds.origin.x)
            let dy = abs(f.origin.y - hitBounds.origin.y)
            if dx > 40 || dy > 40 {
                return
            }
        }

        isDragging = true
        windowMoved = false
        lastMoveGate = .distantPast
        draggedWindow = resolved
        originalFrame = AX.frame(of: resolved)
        currentSnapZone = nil
        selectorActive = false
        Log.info("拖拽分屏：开始跟踪窗口 #\(hitWid)")
    }

    // MARK: - 鼠标拖拽

    private func handleMouseDragged(_ event: CGEvent) {
        guard isDragging else { return }
        let cg = event.location

        // 闸门：仅当窗口 frame 本身在移动时才触发吸附（节流的 AX 查询，便宜，
        // 避免「选中了文本却弹出吸附栏」的误触发）。
        if !windowMoved {
            let now = Date()
            guard now.timeIntervalSince(lastMoveGate) > 0.05 else { return }
            lastMoveGate = now
            guard let win = draggedWindow, let orig = originalFrame,
                  let f = AX.frame(of: win) else { return }
            if abs(f.origin.x - orig.origin.x) > 8 || abs(f.origin.y - orig.origin.y) > 8 {
                windowMoved = true
            } else {
                return
            }
        }

        guard let screen = AX.screenContaining(cg) ?? NSScreen.main else { return }

        // 顶部选择器已激活：拖离顶部区域 -> 关闭；否则更新高亮。
        if selectorActive {
            let f = NSScreen.cgFrame(of: screen)
            if cg.y > f.minY + 260 {
                closeSelector()
                return
            }
            updateSelectorFromDrag(cg: cg)
            return
        }

        // 边缘分屏选择器已激活：把窗口拉离该侧 -> 取消；否则更新高亮。
        if edgeSelectorActive {
            let f = NSScreen.cgFrame(of: screen)
            if (edgeSelectorSide == .left && cg.x > f.midX) ||
               (edgeSelectorSide == .right && cg.x < f.midX) {
                closeEdgeSelector()
                return
            }
            updateEdgeSelectorFromDrag(cg: cg)
            return
        }

        let cfg = context?.config
        let selectorOn = cfg?.edgeSnapSelectorEnabled ?? false

        // 1) 顶部中央 -> 顶部选择器（四块，原行为，不动）。
        if Self.inTopBand(cg, screen: screen) {
            enterSelector(screen: screen)
            return
        }

        // 2) 左 / 右边缘。
        if let side = Self.edgeSide(at: cg, margin: snapMargin, screen: screen) {
            if selectorOn {
                enterEdgeSelector(side: side, screen: screen)
            } else {
                applyPreviewZone(presetKind(for: side), cg: cg)
            }
            return
        }

        // 3) 其它区域：清除预览。
        applyPreviewZone(nil, cg: cg)
    }

    // MARK: - 鼠标抬起 -> 松手 = 确认

    private func handleMouseUp(_ event: CGEvent) {
        guard isDragging else { return }
        isDragging = false
        defer {
            hidePreview()
            draggedWindow = nil
            originalFrame = nil
            currentSnapZone = nil
            windowMoved = false
            closeSelector()
            closeEdgeSelector()
        }
        guard windowMoved else {           // 窗口从未移动 -> 普通点击
            return
        }
        let cg = event.location
        guard let screen = AX.screenContaining(cg) ?? NSScreen.main else { return }
        let vf = NSScreen.cgVisibleFrame(of: screen)

        if edgeSelectorActive {
            if let kind = edgeSelectorModel.activeKind, let win = draggedWindow {
                applySnap(win: win, kind: kind)
            } else {
                Log.info("边缘分屏选择器：松手位置不在分区内，已取消")
            }
            return
        }

        if selectorActive {
            // 严格：仅当光标此刻落在某个子分区内才应用。滑入 = 选中，滑出 = 取消；
            // 在栏外任何位置松手都取消——无回退。
            if let zone = resolvePick(for: cg).zone, let win = draggedWindow {
                applySnap(win: win, kind: zone)
            } else {
                Log.info("顶部分屏选择器：松手位置不在分区内，已取消")
            }
            return
        }

        if let zone = currentSnapZone, let win = draggedWindow {
            let gap = CGFloat(context?.config.gap ?? 0)
            let target = SnapLayout.compute(kind: zone, visibleFrame: vf, gap: gap)
            AX.setFrameSnapped(win, target: target, visibleFrame: vf)
            Log.info("边缘分屏: \(zone.rawValue) -> \(target)")
        }
    }

    // MARK: - 选择器生命周期

    private func enterSelector(screen: NSScreen) {
        selectorActive = true
        hidePreview()
        selectorScreen = screen

        // 一次性在 CG 全局坐标中计算所有几何。
        let f = NSScreen.cgFrame(of: screen)
        let vf = NSScreen.cgVisibleFrame(of: screen)
        barRectCG = CGRect(
            x: vf.midX - barW / 2,
            y: vf.minY + 16,   // 菜单栏 / 刘海正下方，固定位置
            width: barW, height: barH
        )

        // 预计算块 rect（等宽，均匀间隔）。
        blockRectsCG = []
        let pad: CGFloat = 12
        let innerW = barW - pad * 2
        let gapCount = CGFloat(barBlocks.count - 1)
        let blockGap: CGFloat = 12
        let blockW = (innerW - gapCount * blockGap) / CGFloat(barBlocks.count)
        let blockH = barH - pad * 2
        var x = barRectCG.minX + pad
        for b in barBlocks {
            blockRectsCG.append((b, CGRect(x: x, y: barRectCG.minY + pad, width: blockW, height: blockH)))
            x += blockW + blockGap
        }

        // 填充共享 SwiftUI 模型（本地坐标，原点在屏幕左上）。
        selectorModel.screenSize = CGSize(width: f.width, height: f.height)
        selectorModel.barRect = CGRect(x: barRectCG.minX - f.minX, y: barRectCG.minY - f.minY,
                                       width: barRectCG.width, height: barRectCG.height)
        selectorModel.blocks = blockRectsCG.map { (layout, r) in
            (layout, CGRect(x: r.minX - f.minX, y: r.minY - f.minY, width: r.width, height: r.height))
        }
        selectorModel.activeLayout = nil
        selectorModel.activeZone = nil
        selectorModel.overlayCells = []

        ensureSelectorPanel(screenFrame: f)
        startKeepAlive()
        Log.info("顶部分屏选择器已激活（悬停高亮，松手应用）")
    }

    /// 拖拽时高亮随光标通过 tap 更新。滑入子分区 -> 点亮；滑出 -> 立即清除
    /// （这样在栏外松手绝不应用任何东西）。
    private func updateSelectorFromDrag(cg: CGPoint) {
        selectorPanel?.orderFrontRegardless()
        let pick = resolvePick(for: cg)
        if let layout = pick.block, let zone = pick.zone {
            setSelection(layout: layout, zone: zone)
        } else {
            clearSelection()
        }
    }

    private func clearSelection() {
        guard selectorModel.activeZone != nil || selectorModel.activeLayout != nil else { return }
        selectorModel.activeLayout = nil
        selectorModel.activeZone = nil
        selectorModel.overlayCells = []
    }

    /// 更新高亮块 / 分区 + 全屏覆盖预览。
    private func setSelection(layout: BlockLayout, zone: SnapKind) {
        guard let screen = selectorScreen else { return }
        selectorModel.activeLayout = layout
        selectorModel.activeZone = zone
        let f = NSScreen.cgFrame(of: screen)
        let vf = NSScreen.cgVisibleFrame(of: screen)
        let gap = CGFloat(context?.config.gap ?? 0)
        let r = SnapLayout.compute(kind: zone, visibleFrame: vf, gap: gap)
        selectorModel.overlayCells = [(zone, CGRect(x: r.minX - f.minX, y: r.minY - f.minY,
                                                    width: r.width, height: r.height))]
    }

    /// 解析光标映射到哪个块 + 子分区。
    /// 严格命中测试：光标必须同时在块的水平和垂直范围内（仅给手抖留极小容差）。
    /// 仅仅进入顶部带 / 栏背景都不会选中任何东西。
    private func resolvePick(for cg: CGPoint) -> (block: BlockLayout?, zone: SnapKind?) {
        for (layout, r) in blockRectsCG {
            if cg.x >= r.minX - 6, cg.x <= r.maxX + 6,
               cg.y >= r.minY - 8, cg.y <= r.maxY + 8 {
                let cx = min(max(cg.x, r.minX), r.maxX)
                let cy = min(max(cg.y, r.minY), r.maxY)
                let zone = zoneForBlock(layout, at: CGPoint(x: cx, y: cy), block: r)
                return (layout, zone)
            }
        }
        return (nil, nil)
    }

    private func zoneForBlock(_ layout: BlockLayout, at p: CGPoint, block r: CGRect) -> SnapKind {
        let nx = (p.x - r.minX) / max(r.width, 1)
        let ny = (p.y - r.minY) / max(r.height, 1)
        switch layout {
        case .half:  return nx < 0.5 ? .leftHalf : .rightHalf
        case .third: return nx < 1.0 / 3.0 ? .leftThird : (nx < 2.0 / 3.0 ? .centerThird : .rightThird)
        case .quad:
            let left = nx < 0.5
            let top  = ny < 0.5
            if left && top  { return .topLeft }
            if !left && top { return .topRight }
            if left && !top { return .bottomLeft }
            return .bottomRight
        case .vert:  return ny < 0.5 ? .topHalf : .bottomHalf
        }
    }

    // MARK: - 单个全屏面板（创建一次；frame = 屏幕，永不改变）

    private func ensureSelectorPanel(screenFrame: CGRect) {
        if selectorPanel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: Int(screenFrame.width), height: Int(screenFrame.height)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            p.level = Self.selectorLevel
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isOpaque = false
            p.ignoresMouseEvents = true   // 始终——面板永不捕获鼠标
            p.contentViewController = NSHostingController(
                rootView: FixedSelectorRootView(model: selectorModel))
            selectorPanel = p
        }
        // frame 精确设为屏幕——拖拽期间永不改变。
        selectorPanel?.setFrame(Coordinates.cgRectToCocoa(screenFrame), display: true)
        selectorPanel?.orderFrontRegardless()
    }

    /// 周期性重新断言 z 序，使栏永不下沉或消失。
    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.selectorActive else { return }
            self.selectorPanel?.orderFrontRegardless()
        }
        RunLoop.main.add(keepAliveTimer!, forMode: .common)
    }

    private func closeSelector() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        selectorPanel?.orderOut(nil)
        selectorActive = false
        selectorModel.activeLayout = nil
        selectorModel.activeZone = nil
        selectorModel.overlayCells = []
        blockRectsCG = []
    }

    /// 将吸附区域应用到被拖窗口。
    private func applySnap(win: AXUIElement, kind: SnapKind) {
        guard let screen = selectorScreen ?? NSScreen.main else { return }
        let vf = NSScreen.cgVisibleFrame(of: screen)
        let gap = CGFloat(context?.config.gap ?? 0)
        let target = SnapLayout.compute(kind: kind, visibleFrame: vf, gap: gap)
        AX.setFrameSnapped(win, target: target, visibleFrame: vf)
        Log.info("顶部分屏(松手确认): \(kind.rawValue) -> \(target)")
    }

    // MARK: - 边缘分屏选择器（4 选项，每块内小方块可选）

    /// 预设默认分屏比例（「边缘分屏选择器」关闭时，拖到对应边缘直接吸附此比例）。
    private func presetKind(for side: EdgeSide) -> SnapKind {
        let cfg = context?.config
        if side == .left {
            switch cfg?.edgeSnapLeftLayout ?? .half {
            case .third:     return .leftThird
            case .half:      return .leftHalf
            case .twoThirds: return .leftTwoThirds
            }
        } else {
            switch cfg?.edgeSnapRightLayout ?? .half {
            case .third:     return .rightThird
            case .half:      return .rightHalf
            case .twoThirds: return .rightTwoThirds
            }
        }
    }

    /// 设置 / 刷新普通边缘吸附预览（预设分屏）。
    private func applyPreviewZone(_ zone: SnapKind?, cg: CGPoint) {
        if zone != currentSnapZone {
            currentSnapZone = zone
            if let zone { showPreview(snapZone: zone, cursor: cg) } else { hidePreview() }
        } else if let zone {
            updatePreview(snapZone: zone, cursor: cg)
        }
    }

    /// 进入边缘分屏选择器：在左 / 右边缘内侧弹出 4 个选项块，每块是一个显示器比例
    /// 的圆角矩形，内部小方块（对应一个绝对屏幕区域）可单独悬停选中。左 / 右选择器
    /// 内容完全一致，仅面板出现位置与说明文字位置不同。
    private func enterEdgeSelector(side: EdgeSide, screen: NSScreen) {
        closeSelector()
        edgeSelectorActive = true
        edgeSelectorSide = side
        selectorScreen = screen
        hidePreview()

        let f = NSScreen.cgFrame(of: screen)
        let vf = NSScreen.cgVisibleFrame(of: screen)

        let sw: CGFloat = 232          // 选择器宽度
        let margin: CGFloat = 30       // 距边缘距离
        let blockGap: CGFloat = 16     // 选项块间距
        let pad: CGFloat = 12          // 块内边距
        let titleH: CGFloat = 22       // 标题高度
        let innerGap: CGFloat = 6      // 小方块间距
        let blockH = sw * 0.6          // 显示器比例（宽:高 ≈ 5:3）

        let n = CGFloat(EdgeOption.allCases.count)
        let totalH = n * blockH + (n - 1) * blockGap
        let stripX = (side == .left) ? vf.minX + margin : vf.maxX - margin - sw
        let stripY = vf.midY - totalH / 2

        var optionRectsLocal: [CGRect] = []
        var optionTitlesLocal: [String] = []
        var cellsLocal: [(SnapKind, CGRect)] = []

        for (i, opt) in EdgeOption.allCases.enumerated() {
            let bx = stripX
            let by = stripY + CGFloat(i) * (blockH + blockGap)
            let blockRect = CGRect(x: bx, y: by, width: sw, height: blockH)
            optionRectsLocal.append(blockRect)
            optionTitlesLocal.append(opt.title)

            let innerLeft = bx + pad
            let innerRight = bx + sw - pad
            let innerTop = by + titleH
            let innerBottom = by + blockH - pad
            let innerW = innerRight - innerLeft
            let innerH = innerBottom - innerTop
            for (kind, z) in opt.zones {
                var tr = CGRect(x: innerLeft + z.minX * innerW,
                                y: innerTop + z.minY * innerH,
                                width: z.width * innerW,
                                height: z.height * innerH)
                tr = tr.insetBy(dx: innerGap / 2, dy: innerGap / 2)
                cellsLocal.append((kind, tr))
            }
        }

        let panelRect = CGRect(x: stripX - 10, y: stripY - 10,
                               width: sw + 20, height: totalH + 20)

        edgeOptionRectsCG = optionRectsLocal
        edgeCellsCG = cellsLocal

        edgeSelectorModel.screenSize = CGSize(width: f.width, height: f.height)
        edgeSelectorModel.panelRect = CGRect(x: panelRect.minX - f.minX, y: panelRect.minY - f.minY,
                                             width: panelRect.width, height: panelRect.height)
        edgeSelectorModel.optionRects = optionRectsLocal.map { r in
            CGRect(x: r.minX - f.minX, y: r.minY - f.minY, width: r.width, height: r.height) }
        edgeSelectorModel.optionTitles = optionTitlesLocal
        edgeSelectorModel.cells = cellsLocal.map { (k, r) in
            (k, CGRect(x: r.minX - f.minX, y: r.minY - f.minY, width: r.width, height: r.height)) }
        edgeSelectorModel.activeKind = nil
        edgeSelectorModel.overlayCells = []

        // 竖排说明文字：左选择器在右侧、右选择器在左侧。
        let capText = IadenteL10n.t("悬停选区域 · 松手应用 · 拖离边缘取消", "Hover to select · release to apply · drag off edge to cancel")
        let capX = (side == .left) ? (stripX + sw + 16) : (stripX - 16)
        let capY = stripY + totalH / 2
        edgeSelectorModel.captionText = capText
        edgeSelectorModel.captionX = capX - f.minX
        edgeSelectorModel.captionY = capY - f.minY

        ensureEdgeSelectorPanel(screenFrame: f)
        startEdgeKeepAlive()
        Log.info("边缘分屏选择器已激活（\(side == .left ? "左" : "右")，4 选项各小方块可选，松手应用）")
    }

    private func updateEdgeSelectorFromDrag(cg: CGPoint) {
        edgeSelectorPanel?.orderFrontRegardless()
        var picked: SnapKind? = nil
        for (k, r) in edgeCellsCG {
            if cg.x >= r.minX - 6, cg.x <= r.maxX + 6,
               cg.y >= r.minY - 6, cg.y <= r.maxY + 6 {
                picked = k
                break
            }
        }
        if let k = picked { setEdgeSelection(kind: k) } else { clearEdgeSelection() }
    }

    private func setEdgeSelection(kind: SnapKind) {
        guard let screen = selectorScreen else { return }
        edgeSelectorModel.activeKind = kind
        let f = NSScreen.cgFrame(of: screen)
        let vf = NSScreen.cgVisibleFrame(of: screen)
        let gap = CGFloat(context?.config.gap ?? 0)
        let r = SnapLayout.compute(kind: kind, visibleFrame: vf, gap: gap)
        edgeSelectorModel.overlayCells = [(kind, CGRect(x: r.minX - f.minX, y: r.minY - f.minY,
                                                        width: r.width, height: r.height))]
    }

    private func clearEdgeSelection() {
        guard edgeSelectorModel.activeKind != nil else { return }
        edgeSelectorModel.activeKind = nil
        edgeSelectorModel.overlayCells = []
    }

    private func ensureEdgeSelectorPanel(screenFrame: CGRect) {
        if edgeSelectorPanel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: Int(screenFrame.width), height: Int(screenFrame.height)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            p.level = Self.selectorLevel
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isOpaque = false
            p.ignoresMouseEvents = true
            p.contentViewController = NSHostingController(
                rootView: EdgeSelectorRootView(model: edgeSelectorModel))
            edgeSelectorPanel = p
        }
        edgeSelectorPanel?.setFrame(Coordinates.cgRectToCocoa(screenFrame), display: true)
        edgeSelectorPanel?.orderFrontRegardless()
    }

    private func startEdgeKeepAlive() {
        edgeKeepAliveTimer?.invalidate()
        edgeKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.edgeSelectorActive else { return }
            self.edgeSelectorPanel?.orderFrontRegardless()
        }
        RunLoop.main.add(edgeKeepAliveTimer!, forMode: .common)
    }

    private func closeEdgeSelector() {
        edgeKeepAliveTimer?.invalidate()
        edgeKeepAliveTimer = nil
        edgeSelectorPanel?.orderOut(nil)
        edgeSelectorActive = false
        edgeSelectorModel.activeKind = nil
        edgeSelectorModel.overlayCells = []
        edgeSelectorModel.panelRect = .zero
        edgeSelectorModel.optionRects = []
        edgeSelectorModel.optionTitles = []
        edgeSelectorModel.captionText = ""
        edgeCellsCG = []
        edgeOptionRectsCG = []
    }

    // MARK: - 辅助

    /// 当指针在屏幕中部一半范围内「越过菜单栏底边」时打开选择器。
    ///
    /// 触发线 = `visibleFrame.minY`（CG 坐标），即菜单栏结束、桌面工作区开始处。
    /// 普通窗口移动停留在那条线以下，因此不会误触发；且不同于之前的「撞到物理
    /// 顶部边缘（±4px）」规则，用户无需推到最顶端——进入菜单栏条带即可，手感更舒适。
    static func inTopBand(_ cg: CGPoint, screen: NSScreen) -> Bool {
        let f = NSScreen.cgFrame(of: screen)
        let vf = NSScreen.cgVisibleFrame(of: screen)
        return cg.y < vf.minY && abs(cg.x - f.midX) < f.width * 0.25
    }

    /// 边缘检测：光标是否贴近左 / 右边缘（在可见帧 margin 内）。
    static func edgeSide(at point: CGPoint, margin: CGFloat, screen: NSScreen) -> EdgeSide? {
        let vf = NSScreen.cgVisibleFrame(of: screen)
        if abs(point.x - vf.minX) < margin { return .left }
        if abs(point.x - vf.maxX) < margin { return .right }
        return nil
    }

    // MARK: - 边缘吸附预览面板

    private func showPreview(snapZone: SnapKind, cursor: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { NSScreen.cgFrame(of: $0).contains(cursor) })
              ?? NSScreen.main else { return }
        let vf = NSScreen.cgVisibleFrame(of: screen)
        let gap = CGFloat(context?.config.gap ?? 0)
        let target = SnapLayout.compute(kind: snapZone, visibleFrame: vf, gap: gap)
        if previewPanel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isOpaque = false
            p.ignoresMouseEvents = true
            previewPanel = p
        }
        previewPanel?.contentViewController = NSHostingController(rootView: EdgeSnapPreviewView(targetFrame: target))
        previewPanel?.setFrame(target, display: true)
        previewPanel?.orderFrontRegardless()
    }

    private func updatePreview(snapZone: SnapKind, cursor: CGPoint) {
        showPreview(snapZone: snapZone, cursor: cursor)
    }

    private func hidePreview() { previewPanel?.orderOut(nil) }
}

// MARK: - 块布局类型

enum BlockLayout: String {
    case half, third, quad, vert
    var title: String {
        switch self {
        case .half:  return IadenteL10n.t("2等分", "Halves")
        case .third: return IadenteL10n.t("3等分", "Thirds")
        case .quad:  return IadenteL10n.t("四象限", "Quadrants")
        case .vert:  return IadenteL10n.t("上下", "Top/Bottom")
        }
    }

    /// 该块的子分区，归一化（0-1）坐标。
    ///
    /// 注意：每个字面量都显式带小数点。所有整数字面量的 `CGRect(x: 1/3, ...)`
    /// 会因整数除法解析到 **Int** 构造器，使 `1/3 == 0`——那个 bug 让三个三等分
    /// 单元零宽：不可见字形 AND 不可选分区。
    var zones: [(SnapKind, CGRect)] {
        let third: CGFloat = 1.0 / 3.0
        switch self {
        case .half:
            return [(.leftHalf,  CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)),
                    (.rightHalf, CGRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0))]
        case .third:
            return [(.leftThird,   CGRect(x: 0.0,       y: 0.0, width: third, height: 1.0)),
                    (.centerThird, CGRect(x: third,     y: 0.0, width: third, height: 1.0)),
                    (.rightThird,  CGRect(x: third * 2, y: 0.0, width: third, height: 1.0))]
        case .quad:
            return [(.topLeft,     CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)),
                    (.topRight,    CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5)),
                    (.bottomLeft,  CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5)),
                    (.bottomRight, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))]
        case .vert:
            return [(.topHalf,    CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5)),
                    (.bottomHalf, CGRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5))]
        }
    }
}

// MARK: - 边缘吸附预览矩形

struct EdgeSnapPreviewView: View {
    let targetFrame: CGRect
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.25))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.6), lineWidth: 2))
            .frame(width: targetFrame.width, height: targetFrame.height)
    }
}

// MARK: - 共享选择器状态（可观察，使视图只创建一次）

/// 特性（事件 tap）与 SwiftUI 之间的状态桥。宿主视图观察此模型；更新发布属性
/// 会重渲内容而**不**重建控制器，因此面板始终稳定。
final class SelectorModel: ObservableObject {
    @Published var screenSize: CGSize = .zero
    @Published var barRect: CGRect = .zero
    @Published var blocks: [(BlockLayout, CGRect)] = []
    @Published var activeLayout: BlockLayout?
    @Published var activeZone: SnapKind?
    @Published var overlayCells: [(SnapKind, CGRect)] = []
}

// MARK: - === 单个全屏选择器视图 ===
// 根视图填满整个屏幕。在其中，黑色栏与覆盖层定位在固定绝对坐标。由于父 NSPanel
// 的 frame 永不改变且宿主控制器只创建一次，没有任何东西会「跳」或消失。面板
// 忽略所有鼠标事件——高亮完全由拖拽期间的事件 tap 驱动。

struct FixedSelectorRootView: View {
    @ObservedObject var model: SelectorModel
    /// 自动跟随系统浅色/深色外观。
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1) 全屏覆盖高亮（选中的吸附分区）。
            ForEach(model.overlayCells.indices, id: \.self) { i in
                let (_, r) = model.overlayCells[i]
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.92), lineWidth: 3))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }

            // 2) 栏背景，固定在刘海下方。
            RoundedRectangle(cornerRadius: 16)
                .fill(MTheme.panel(scheme))
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 12, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(MTheme.hairline(scheme), lineWidth: 1)
                )
                .frame(width: model.barRect.width, height: model.barRect.height)
                .position(x: model.barRect.midX, y: model.barRect.midY)

            // 3) 块瓦片（纯展示；命中测试在事件 tap 内）。
            ForEach(model.blocks.indices, id: \.self) { i in
                let (layout, r) = model.blocks[i]
                BlockTileView(
                    layout: layout,
                    rect: r,
                    isActive: layout == model.activeLayout,
                    activeZone: layout == model.activeLayout ? model.activeZone : nil
                )
            }

            // 4) 提示文本。
            Text(IadenteL10n.t("滑入分区选中 · 松手应用 · 滑出分区或拖离顶部取消", "Hover to select · release to apply · drag out or off top to cancel"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(MTheme.primaryText(scheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(MTheme.panel(scheme))
                        .overlay(Capsule().stroke(MTheme.hairline(scheme), lineWidth: 1))
                )
                .position(x: model.barRect.midX, y: model.barRect.maxY + 20)
        }
        .frame(width: model.screenSize.width, height: model.screenSize.height, alignment: .topLeading)
    }
}

// MARK: - 栏内单个块瓦片

struct BlockTileView: View {
    let layout: BlockLayout
    let rect: CGRect
    let isActive: Bool
    let activeZone: SnapKind?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // 瓦片背景。
            RoundedRectangle(cornerRadius: 12)
                .fill(MTheme.surface(scheme, active: isActive))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(MTheme.surfaceStroke(scheme, active: isActive),
                                lineWidth: isActive ? 1.5 : 0.5)
                )

            // 分屏图案的迷你字形。
            BlockGlyphMini(layout: layout, activeZone: activeZone)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - 单个块瓦片的迷你字形绘制

/// 把分屏图案绘制成等宽圆角单元 + 均匀间隙——2 等分 = 两个相同半屏，3 等分 =
/// 三个相同列，四象限 = 四个相同象限，上下 = 两个相同行。悬停/选中的单元点亮。
struct BlockGlyphMini: View {
    let layout: BlockLayout
    let activeZone: SnapKind?
    @Environment(\.colorScheme) private var scheme

    /// 单元间间隙（以及外边缘的一半）。
    private let cellGap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ForEach(layout.zones.indices, id: \.self) { i in
                    let (kind, n) = layout.zones[i]
                    let cw = max(n.width  * w - cellGap, 2)
                    let ch = max(n.height * h - cellGap, 2)
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(MTheme.glyph(scheme, active: kind == activeZone))
                    .frame(width: cw, height: ch)
                    .position(x: n.midX * w, y: n.midY * h)
            }
        }
    }
}
}

// MARK: - 边缘选择器类型

/// 左 / 右边缘。
enum EdgeSide {
    case left
    case right
}

/// 边缘分屏选择器的共享状态（事件 tap 与 SwiftUI 之间的桥）。
final class EdgeSelectorModel: ObservableObject {
    @Published var screenSize: CGSize = .zero
    @Published var panelRect: CGRect = .zero
    @Published var optionRects: [CGRect] = []
    @Published var optionTitles: [String] = []
    @Published var cells: [(SnapKind, CGRect)] = []
    @Published var activeKind: SnapKind?
    @Published var overlayCells: [(SnapKind, CGRect)] = []
    @Published var captionText: String = ""
    @Published var captionX: CGFloat = 0
    @Published var captionY: CGFloat = 0
}

/// 边缘选择器的 4 个选项（左 / 右通用，内容一致，仅出现位置不同）。
enum EdgeOption: CaseIterable {
    case triple     // 三分屏
    case half       // 两分屏（均等）
    case thirdTwo   // (1/3, 2/3)
    case twoThird   // (2/3, 1/3)

    var title: String {
        switch self {
        case .triple:   return IadenteL10n.t("三分屏", "Thirds")
        case .half:     return IadenteL10n.t("两分屏", "Halves")
        case .thirdTwo: return "1/3 · 2/3"
        case .twoThird: return "2/3 · 1/3"
        }
    }

    /// 该选项内部的小方块（归一化 0–1 坐标，x 向右、y 向下），每个对应一个绝对屏幕区域。
    /// 注意：所有字面量显式带小数点——`1/3` 会被解析为 Int 构造器导致零宽（同顶部选择器旧 bug）。
    var zones: [(SnapKind, CGRect)] {
        let t: CGFloat = 1.0 / 3.0
        switch self {
        case .triple:
            return [(.leftThird,    CGRect(x: 0.0,       y: 0.0, width: t,       height: 1.0)),
                    (.centerThird,  CGRect(x: t,         y: 0.0, width: t,       height: 1.0)),
                    (.rightThird,   CGRect(x: t * 2.0,   y: 0.0, width: t,       height: 1.0))]
        case .half:
            return [(.leftHalf,  CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)),
                    (.rightHalf, CGRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0))]
        case .thirdTwo:
            return [(.leftThird,      CGRect(x: 0.0,         y: 0.0, width: t,       height: 1.0)),
                    (.rightTwoThirds, CGRect(x: t,           y: 0.0, width: t * 2.0, height: 1.0))]
        case .twoThird:
            return [(.leftTwoThirds, CGRect(x: 0.0,     y: 0.0, width: t * 2.0, height: 1.0)),
                    (.rightThird,    CGRect(x: t * 2.0, y: 0.0, width: t,       height: 1.0))]
        }
    }
}

/// 边缘分屏选择器根视图（填满全屏，面板固定在边缘内侧）。
struct EdgeSelectorRootView: View {
    @ObservedObject var model: EdgeSelectorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1) 全屏覆盖高亮（选中的吸附分区）。
            ForEach(model.overlayCells.indices, id: \.self) { i in
                let (_, r) = model.overlayCells[i]
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.92), lineWidth: 3))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }

            // 2) 整体面板背景（圆角浮层）。
            if !model.panelRect.isEmpty {
                RoundedRectangle(cornerRadius: 18)
                    .fill(MTheme.panel(scheme))
                    .shadow(color: Color.black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 14, y: 5)
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(MTheme.hairline(scheme), lineWidth: 1))
                    .frame(width: model.panelRect.width, height: model.panelRect.height)
                    .position(x: model.panelRect.midX, y: model.panelRect.midY)
            }

            // 3) 每个选项块背景 + 标题。
            ForEach(model.optionRects.indices, id: \.self) { i in
                let r = model.optionRects[i]
                RoundedRectangle(cornerRadius: 14)
                    .fill(MTheme.surface(scheme, active: false))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(MTheme.surfaceStroke(scheme, active: false), lineWidth: 0.5))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                Text(model.optionTitles[i])
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MTheme.primaryText(scheme))
                    .position(x: r.midX, y: r.minY + 12)
            }

            // 4) 每个小方块（可单独选中）。
            ForEach(model.cells.indices, id: \.self) { i in
                let (kind, r) = model.cells[i]
                EdgeTileView(
                    kind: kind,
                    rect: r,
                    isActive: kind == model.activeKind
                )
            }

            // 5) 竖排说明文字（逐字纵向排列，避免横排放不下）。
            if !model.captionText.isEmpty {
                VerticalCaptionView(text: model.captionText)
                    .position(x: model.captionX, y: model.captionY)
            }
        }
        .frame(width: model.screenSize.width, height: model.screenSize.height, alignment: .topLeading)
    }
}

/// 逐字纵向排列的说明标签（每个字符独立一行，真正的竖排，不是旋转）。
private struct VerticalCaptionView: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    /// 按「词/短语」竖排：英文拆成单词、中文按「·」拆成短语，每个片段横向排、片段间竖排。
    /// 避免原来逐字母竖排导致英文不可读（"H o v e r…"）。
    private var segments: [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "·" }).map(String.init)
    }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(segments, id: \.self) { seg in
                Text(seg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(MTheme.primaryText(scheme))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(MTheme.panel(scheme))
                .overlay(Capsule().stroke(MTheme.hairline(scheme), lineWidth: 1))
        )
    }
}

/// 边缘选择器里单个小方块（每个对应一个绝对屏幕区域，悬停即选中）。
struct EdgeTileView: View {
    let kind: SnapKind
    let rect: CGRect
    let isActive: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(MTheme.glyph(scheme, active: isActive))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MTheme.hairline(scheme), lineWidth: isActive ? 2 : 0.5)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}
