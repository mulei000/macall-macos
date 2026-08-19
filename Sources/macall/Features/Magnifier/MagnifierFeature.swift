import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SwiftUI

// MARK: - 屏幕放大镜（Magnifier）

/// ⌃⌥Z：切换跟随光标的浮窗放大镜，把光标周围区域按比例放大显示。
/// 抓取用 CGDisplayCreateImageForRect，需要「屏幕录制」权限（截图模块已申请）。
final class MagnifierFeature: Feature {
    let id = "magnifier"
    let title = IadenteL10n.t("屏幕放大镜", "Screen Magnifier")
    let category = FeatureCategory.other
    var enabledByDefault: Bool = true

    var isLaunchableTool: Bool { true }
    var launchAction: String? { "toggle" }

    private var context: AppContext?
    private var panel: MagnifierPanelController?
    private var active = false

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[magnifier] 已安装：⌃⌥Z 切换屏幕放大镜")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["magnifier.toggle"]?.toCombo()
            ?? Configuration.defaultHotkeys()["magnifier.toggle"]!.toCombo()
        context?.hotkeys.bind(featureId: id, action: "toggle", configKey: "magnifier.toggle", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "toggle" { toggle() }
    }

    func reload(config: Configuration) { bindHotkey(using: config) }
    func uninstall() { stop() }

    private func toggle() {
        if active { stop() } else { start() }
    }

    private func start() {
        guard !active else { return }
        active = true
        panel = MagnifierPanelController()
        panel?.onEscape = { [weak self] in self?.stop() }
        panel?.show()
        panel?.startTracking { [weak self] point in
            self?.update(at: point)
        }
        // 立即用当前光标位置刷新一次：即使全局鼠标监听还没收到事件，面板也立刻显示
        // 当前位置的放大内容，而不是空等第一次 mouseMoved。
        update(at: NSEvent.mouseLocation)
        Log.info("[magnifier] 已启动")
    }

    private func stop() {
        active = false
        panel?.stopTracking()
        panel?.close()
        panel = nil
        // 把焦点还给被打开放大镜时抢走的 App（与 start 里的 NSApp.activate 配对），
        // 否则关掉放大镜后焦点卡在 macall（无主窗口），体验突兀。
        NSApp.deactivate()
    }

    private func update(at point: NSPoint) {
        let captureSize: CGFloat = 160
        let zoom: CGFloat = CGFloat(context?.config.magnifierZoom ?? 3)
        let cg = toCGGlobal(point)
        guard let (displayID, displayBounds) = displayAndBounds(at: point) else {
            panel?.setImage(nil)
            return
        }
        // clamp 抓取区域到显示器边界内
        var rect = CGRect(x: cg.x - captureSize / 2, y: cg.y - captureSize / 2, width: captureSize, height: captureSize)
        rect = rect.intersection(displayBounds)
        guard !rect.isEmpty, let img = captureRect(rect, displayID: displayID) else {
            panel?.setImage(nil)
            return
        }
        let ns = NSImage(cgImage: img, size: NSSize(width: rect.width * zoom, height: rect.height * zoom))
        panel?.setImage(ns)
        panel?.moveNearCursor()
    }

    /// 用 ScreenCaptureKit（macOS 15.2+ 的 sanctioned API）抓取指定矩形区域的图像。
    /// 同步等待结果（放大镜场景下调用频率受限，短暂阻塞主线程可接受）。
    private func captureRect(_ rect: CGRect, displayID: CGDirectDisplayID) -> CGImage? {
        guard #available(macOS 15.2, *) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var result: CGImage?
        SCScreenshotManager.captureImage(in: rect) { cg, _ in
            result = cg
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 0.5)
        return result
    }

    /// AppKit 坐标（原点左下，跨所有显示器全局）→ Quartz 全局坐标（原点左上，主显示器）。
    /// 必须用「所有屏幕 frame.maxY 的最大值」作为总高度，而非主屏高度——
    /// 当主屏不是最顶的屏幕时，单用主屏高度会算错 y，导致非主显示器上抓取区域错位。
    private func toCGGlobal(_ p: NSPoint) -> CGPoint {
        let totalHeight = NSScreen.screens.map { NSMaxY($0.frame) }.max() ?? 0
        return CGPoint(x: p.x, y: totalHeight - p.y)
    }

    private func displayAndBounds(at point: NSPoint) -> (CGDirectDisplayID, CGRect)? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point),
               let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return (num, CGDisplayBounds(num))
            }
        }
        return nil
    }
}

// MARK: - 面板

private final class MagnifierPanelState: ObservableObject {
    @Published var image: NSImage?
}

private final class MagnifierPanelController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private let state = MagnifierPanelState()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var hostingView: NSHostingView<AnyView>?
    private var lastUpdate = Date.distantPast
    var onEscape: (() -> Void)?

    func show() {
        let content = MagnifierImageView(state: state)
        let hosting = NSHostingView(rootView: AnyView(content))
        hostingView = hosting

        let size = NSSize(width: 500, height: 520)
        let win = MagnifierPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.isFloatingPanel = true
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.contentView = hosting
        // 让放大镜窗口本身不被 ScreenCaptureKit / CGWindow 捕获，避免「自己放大自己」的递归遮挡。
        if #available(macOS 12.3, *) {
            win.sharingType = .none
        }
        window = win

        // ESC 退出：面板成为 key 后，局部监听拦截 keyCode 53 并吞掉事件，防止事件继续传播重复触发其他快捷键。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.onEscape != nil else { return event }
            self?.onEscape?()
            return nil
        }

        // 放大镜面板初始显示在光标右下方；否则创建后窗口不 orderFront，用户看不到。
        moveNearCursor()
        // 关键：macall 是 accessory App（无 Dock 图标），不先激活 App 直接 orderFront 浮层，
        // 系统窗口服务器不会真正显示它（同 QR 浮层必须先 NSApp.activate）。
        // 这是「⌃⌥Z 面板不弹出」的根因。
        NSApp.activate(ignoringOtherApps: true)
        win.orderFrontRegardless()
        win.makeKey()
        Log.info("[magnifier] 面板已弹出")
    }

    /// 把面板放在光标附近，避免挡住正在放大的区域。
    func moveNearCursor() {
        guard let win = window else { return }
        let size = win.frame.size
        let point = NSEvent.mouseLocation
        let offset: CGFloat = 24
        var origin = NSPoint(
            x: point.x + offset,
            y: point.y - offset - size.height
        )
        // 保证不越出当前屏幕
        if let screen = NSScreen.screens.first(where: { NSPointInRect(point, $0.frame) }) ?? NSScreen.main {
            let frame = screen.frame
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        win.setFrameOrigin(origin)
    }

    func setImage(_ image: NSImage?) {
        // 限流：最多每 16ms 刷新一次，避免频繁截屏卡顿。
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= 0.016 else { return }
        lastUpdate = now
        DispatchQueue.main.async { self.state.image = image }
    }

    func startTracking(_ onMove: @escaping (NSPoint) -> Void) {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            onMove(NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            onMove(NSEvent.mouseLocation)
            return event
        }
    }

    func stopTracking() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
    }

    func close() {
        stopTracking()
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        onEscape = nil
        window?.orderOut(nil)
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopTracking()
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        onEscape = nil
        window = nil
    }
}

/// 让放大镜浮层能成为 key window，这样 ESC 局部监听才能收到事件。
private final class MagnifierPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct MagnifierImageView: View {
    @ObservedObject var state: MagnifierPanelState

    var body: some View {
        Group {
            if let img = state.image {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(Text(IadenteL10n.t("移动光标放大", "Move cursor to magnify"))
                        .foregroundStyle(.secondary))
            }
        }
        .frame(width: 500, height: 500)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.25), lineWidth: 1))
    }
}
