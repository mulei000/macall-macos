import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

// MARK: - 置顶覆盖层（参考 GitHub 上的 Topit）
//
// ## 为什么要换掉「AXRaise + 看门狗」
//
// 旧实现是让目标 App 自己反复执行 `kAXRaiseAction`，靠一个 0.45s 的定时器发现「钉住的窗口
// 掉下去了」再补一次 raise。问题是**这套机制天生要闪**：
//
//   * 补 raise 与用户 / 系统的 z 序变更之间总有一个窗口期，掉下去→抬起来的往复就是闪烁；
//   * 部分 App（Electron / Java 系）被 AXRaise 会顺带激活自己，回弹一条 didActivateApplication，
//     于是「raise → 激活 → raise」自激成环，肉眼看到的就是高速闪；
//   * 两个窗口同时钉住时还会互相压制。
//
// 之前为此加了四道闸门（静默期 / 鼠标按下不动 / 已占最前 N 位收手 / 不碰最小化），
// 闪的频率降低了但没有根治——**只要还在跟 WindowServer 抢 z 序，就一定有掉下去的那一帧**。
//
// ## Topit 的做法（本文件实现的方案）
//
// 干脆不抢 z 序：用 ScreenCaptureKit 实时捕获目标窗口的画面，画到**我们自己进程的**
// 一个 `.floating` 无边框面板上，面板严丝合缝地盖在目标窗口原位。
// 面板是我们自己的窗口，WindowServer 天然允许它浮在普通窗口之上，一帧都不会掉下去，
// 所以**根本不存在闪烁**。目标窗口自己保持不动，被谁盖住都无所谓——用户看到的是覆盖层。
//
// 交互靠「让位」完成：鼠标移到覆盖层上时，把真窗口激活并抬到最前，同时把覆盖层内容
// 透明度降到 0。macOS 的窗口命中测试基于渲染后的 alpha，完全透明的区域点击会**穿透**到
// 下面的真窗口，于是用户直接操作的就是真窗口本身。鼠标移开后恢复捕获与显示。
//
// ## 代价
//
// 需要「屏幕录制」权限（捕获窗口画面），以及「辅助功能」权限（让位时抬升真窗口）。
// 钉住的窗口越多越耗电，与 Topit 相同。

/// 承载 `AVSampleBufferDisplayLayer` 的裸视图。
///
/// 不用 SwiftUI：这里每秒要吞 60 帧，越薄越好；而且需要精确控制 alpha 以触发点击穿透。
final class PinCaptureView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        displayLayer.videoGravity = .resize
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 丢弃已排队的帧。窗口尺寸变了却还在放旧帧，会看到一帧被拉伸的糊图。
    func flushFrames() {
        displayLayer.sampleBufferRenderer.flush()
    }
}

/// 单个窗口的 ScreenCaptureKit 取流器。
///
/// 独立成类是因为 `SCStreamOutput` 的回调在后台队列上，而覆盖层控制器是 `@MainActor`；
/// 把跨线程的部分圈在这里，控制器那边就能保持全主线程。
final class PinCaptureStream: NSObject, SCStreamDelegate, SCStreamOutput {
    private let configuration = SCStreamConfiguration()
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private weak var view: PinCaptureView?

    /// 取流中途失败（窗口最小化 / 切到别的 Space / 权限被撤销）时回调，主线程。
    var onFailure: (@Sendable () -> Void)?

    private(set) var isRunning = false

    init(view: PinCaptureView) {
        self.view = view
        super.init()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 3
    }

    func start(window: SCWindow, screen: NSScreen?) async -> Bool {
        guard stream == nil else { return true }
        let f = SCContentFilter(desktopIndependentWindow: window)
        filter = f
        applySize(width: f.contentRect.width, height: f.contentRect.height,
                  scale: CGFloat(f.pointPixelScale), screen: screen)
        return await launch()
    }

    /// 停过之后原地恢复。先复用上次的 filter；如果 filter 已失效（如窗口最小化后），
    /// 就重新枚举 SCShareableContent 建立新 filter。
    func resume(windowID: CGWindowID, size: CGSize, screen: NSScreen?) async -> Bool {
        guard stream == nil else { return true }
        applySize(width: size.width, height: size.height,
                  scale: screen?.backingScaleFactor ?? 2, screen: screen)
        if filter != nil, await launch() { return true }
        return await restart(windowID: windowID, size: size, screen: screen)
    }

    private func restart(windowID: CGWindowID, size: CGSize, screen: NSScreen?) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return false
            }
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            applySize(width: size.width, height: size.height,
                      scale: screen?.backingScaleFactor ?? 2, screen: screen)
            return await launch()
        } catch {
            return false
        }
    }

    private func launch() async -> Bool {
        guard let filter else { return false }
        do {
            let s = SCStream(filter: filter, configuration: configuration, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await s.startCapture()
            stream = s
            isRunning = true
            return true
        } catch {
            stream = nil
            isRunning = false
            Log.warning("[alwaysontop] 取流失败：\(error.localizedDescription)")
            return false
        }
    }

    func updateSize(_ size: CGSize, screen: NSScreen?) {
        applySize(width: size.width, height: size.height,
                  scale: screen?.backingScaleFactor ?? 2, screen: screen)
        stream?.updateConfiguration(configuration) { error in
            if let error { Log.warning("[alwaysontop] 更新取流尺寸失败：\(error.localizedDescription)") }
        }
    }

    private func applySize(width: CGFloat, height: CGFloat, scale: CGFloat, screen: NSScreen?) {
        let s = max(1, scale)
        configuration.width = max(2, Int(width * s))
        configuration.height = max(2, Int(height * s))
        let fps = max(30, screen?.maximumFramesPerSecond ?? 60)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        isRunning = false
        s.stopCapture { _ in }
        DispatchQueue.main.async { [weak view] in view?.flushFrames() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        DispatchQueue.main.async { [weak self] in
            guard let renderer = self?.view?.displayLayer.sampleBufferRenderer else { return }
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sampleBuffer)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        isRunning = false
        let cb = onFailure
        DispatchQueue.main.async { cb?() }
    }
}

/// 覆盖层面板。必须能成为 key 窗口（否则里面什么都点不到），
/// 但用 `.nonactivatingPanel` 避免点一下就把 macall 整个激活到最前。
final class PinOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 覆盖层控制器

/// 一个被钉住的窗口 = 一个 `PinOverlay`。
@MainActor
final class PinOverlay {
    let windowID: CGWindowID
    let appName: String
    let ownerPID: pid_t

    private let panel: PinOverlayPanel
    private let captureView: PinCaptureView
    private let stream: PinCaptureStream
    private let badge: NSImageView
    private var axWindow: AXUIElement?
    private var follow: Timer?
    private let onClosed: (CGWindowID) -> Void

    /// 鼠标已移入覆盖层，前台已让给真窗口，覆盖层处于「透明穿透」状态。
    private var handedOff = false
    /// 目标窗口当前不在本 Space / 已最小化，覆盖层暂时收起。
    private var offScreen = false
    /// 正在等待一次异步 resume，避免每个 tick 都发起一次。
    private var resuming = false
    private var closed = false

    /// 跟随巡检间隔。与 Topit 一致：0.2s 足够跟手，又不至于烧电。
    private static let followInterval: TimeInterval = 0.2

    private init(windowID: CGWindowID, appName: String, ownerPID: pid_t,
                 frame: NSRect, onClosed: @escaping (CGWindowID) -> Void) {
        self.windowID = windowID
        self.appName = appName
        self.ownerPID = ownerPID
        self.onClosed = onClosed

        captureView = PinCaptureView(frame: NSRect(origin: .zero, size: frame.size))
        captureView.autoresizingMask = [.width, .height]
        stream = PinCaptureStream(view: captureView)

        // 左上角置顶标识：蓝色系，带阴影，确保在深浅背景下都看得清。
        badge = NSImageView(frame: NSRect(x: 6, y: frame.size.height - 28, width: 22, height: 22))
        badge.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(red: 0.24, green: 0.56, blue: 0.98, alpha: 1).cgColor
        badge.layer?.cornerRadius = 5
        badge.layer?.shadowColor = NSColor.black.cgColor
        badge.layer?.shadowOpacity = 0.28
        badge.layer?.shadowRadius = 2
        badge.layer?.shadowOffset = NSSize(width: 0, height: -1)
        badge.autoresizingMask = [.minXMargin, .maxYMargin]
        captureView.addSubview(badge)

        panel = PinOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = captureView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // 覆盖层要能跟到别的 Space、也能盖在全屏 App 之上；
        // 目标窗口不在当前 Space 时由 `offScreen` 分支收起，不会露出错位的画面。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    // MARK: - 创建

    /// 为 `windowID` 建立覆盖层。失败返回 nil（已写日志）。
    static func pin(windowID: CGWindowID, appName: String, ownerPID: pid_t,
                    onClosed: @escaping (CGWindowID) -> Void) async -> PinOverlay? {
        guard let info = windowInfo(of: windowID), info.onScreen else {
            Log.warning("[alwaysontop] wid=\(windowID) 不在屏幕上，无法置顶")
            return nil
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            Log.warning("[alwaysontop] 无法枚举可捕获窗口（多半是缺屏幕录制权限）：\(error.localizedDescription)")
            return nil
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            Log.warning("[alwaysontop] ScreenCaptureKit 里找不到 wid=\(windowID)")
            return nil
        }

        let frame = screenRect(fromCG: info.frame)
        let overlay = PinOverlay(windowID: windowID, appName: appName, ownerPID: ownerPID,
                                 frame: frame, onClosed: onClosed)
        overlay.axWindow = AX.windowWithID(windowID)
        overlay.stream.onFailure = { [weak overlay] in
            MainActor.assumeIsolated { overlay?.handleStreamFailure() }
        }

        let screen = overlay.panel.screen ?? NSScreen.main
        guard await overlay.stream.start(window: scWindow, screen: screen) else {
            overlay.panel.orderOut(nil)
            return nil
        }

        overlay.panel.orderFrontRegardless()
        overlay.startFollowing()
        Log.info("[alwaysontop] 覆盖层已就位 wid=\(windowID) (\(appName)) frame=\(Int(frame.width))×\(Int(frame.height))")
        return overlay
    }

    // MARK: - 跟随

    private func startFollowing() {
        let timer = Timer(timeInterval: Self.followInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common：拖窗口、菜单展开期间也要照常跟随。
        RunLoop.main.add(timer, forMode: .common)
        follow = timer
    }

    private func tick() {
        guard !closed else { return }

        // ① 窗口还在吗？CGWindowList 对最小化 / 切 Space 的窗口可能返回 nil，
        //    但 AX 元素还在，说明只是暂时不可见，不应取消置顶。
        if let info = Self.windowInfo(of: windowID) {
            guard info.onScreen else {
                goOffScreen()
                return
            }
            if offScreen {
                offScreen = false
                Log.info("[alwaysontop] wid=\(windowID) 回到屏幕，覆盖层恢复")
                reclaim()
            }

            // ② 跟随移动 / 改大小。变化的那一帧先把画面藏起来，
            //    否则会看到覆盖层拖着旧画面追赶真窗口。
            let target = Self.screenRect(fromCG: info.frame)
            if !target.equalTo(panel.frame) {
                let sizeChanged = target.size != panel.frame.size
                setContentVisible(false)
                panel.setFrame(target, display: false)
                if sizeChanged {
                    captureView.flushFrames()
                    stream.updateSize(target.size, screen: panel.screen ?? NSScreen.main)
                }
                return
            }
        } else {
            // CGWindowList 找不到，但 AX 元素还在 → 最小化/切 Space，保持置顶。
            if AX.windowWithID(windowID) != nil {
                goOffScreen()
                return
            }
            close(reason: "窗口已关闭")
            return
        }

        // ③ 鼠标在覆盖层上 → 让位给真窗口；移开 → 收回来
        //
        // 用「轮询鼠标位置」而不是 NSTrackingArea：让位期间覆盖层是全透明的，
        // 点击会穿透过去，此时窗口能否收到 mouseExited 并不可靠。轮询没有这个坑。
        if panel.frame.contains(NSEvent.mouseLocation) {
            handOffToRealWindow()
        } else {
            reclaim()
        }
    }

    private func goOffScreen() {
        guard !offScreen else { return }
        offScreen = true
        handedOff = false
        setContentVisible(false)
        stream.stop()
        Log.info("[alwaysontop] wid=\(windowID) 暂时不可见，覆盖层收起（仍保持置顶状态）")
    }

    // MARK: - 让位 / 收回

    /// 鼠标移上来了：把真窗口抬到最前并交出前台，覆盖层变全透明以便点击穿透。
    private func handOffToRealWindow() {
        guard !handedOff else { return }
        handedOff = true
        setContentVisible(false)
        stream.stop()
        if axWindow == nil { axWindow = AX.windowWithID(windowID) }
        AX.focusWindow(axWindow, wid: windowID, pid: ownerPID)
    }

    /// 鼠标移开了：恢复捕获并重新显示覆盖层。
    /// 每个 tick 都会走一遍，所以必须是幂等的。
    private func reclaim() {
        handedOff = false
        guard !offScreen else { return }
        if stream.isRunning {
            setContentVisible(true)
            return
        }
        guard !resuming else { return }
        resuming = true
        let size = panel.frame.size
        let screen = panel.screen ?? NSScreen.main
        Task { [weak self] in
            let ok = await self?.stream.resume(windowID: self?.windowID ?? 0,
                                                size: size, screen: screen) ?? false
            guard let self, !self.closed else { return }
            self.resuming = false
            if ok, !self.handedOff, !self.offScreen {
                self.setContentVisible(true)
            }
        }
    }

    /// 取流中途挂了：先收起，交给下一轮 tick 自愈重试。
    private func handleStreamFailure() {
        guard !closed else { return }
        setContentVisible(false)
    }

    /// 控制覆盖层可见性。
    ///
    /// 关键点：这里改的是**内容视图的 alpha**，不是 `panel.isVisible`。
    /// macOS 的窗口命中测试基于渲染后的 alpha —— 完全透明的区域点击会穿透到下面的真窗口，
    /// 这正是「让位」时我们想要的效果。把面板 orderOut 反而会丢掉 z 序位置。
    private func setContentVisible(_ visible: Bool) {
        captureView.alphaValue = visible ? 1 : 0
        panel.hasShadow = visible
    }

    // MARK: - 关闭

    /// 覆盖层当前在屏幕上的矩形（AppKit 坐标）。
    ///
    /// 即使窗口被最小化而覆盖层进入了 `offScreen`（透明、停流）状态，面板依然
    /// `orderFrontRegardless` 浮在原位、矩形不变。因此「把光标移到窗口原本的位置再按
    /// 快捷键」也能命中这里，从而取消一个已最小化 / 切到别的 App 的置顶窗口。
    var currentFrame: NSRect { panel.frame }

    func close(reason: String? = nil) {
        guard !closed else { return }
        closed = true
        follow?.invalidate()
        follow = nil
        stream.onFailure = nil
        stream.stop()
        panel.orderOut(nil)
        panel.contentView = nil
        if let reason { Log.info("[alwaysontop] 取消置顶 wid=\(windowID) (\(appName))：\(reason)") }
        onClosed(windowID)
    }

    // MARK: - 坐标 / 窗口信息

    /// CoreGraphics 的窗口矩形（原点左上、Y 向下）→ AppKit 屏幕坐标（原点左下、Y 向上）。
    ///
    /// 换算基准必须是**主屏**（`NSScreen.screens.first`，即菜单栏所在那块），
    /// 不是「当前屏」——CG 全局坐标系的原点就定在主屏左上角。用错屏幕在多显示器下会整体错位。
    static func screenRect(fromCG rect: CGRect) -> NSRect {
        guard let main = NSScreen.screens.first else { return rect }
        return NSRect(x: rect.origin.x,
                      y: main.frame.height - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }

    /// 一次 `CGWindowListCopyWindowInfo` 同时拿到矩形和「是否在屏幕上」。
    /// 返回 nil 表示窗口已经不存在了。
    static func windowInfo(of wid: CGWindowID) -> (frame: CGRect, onScreen: Bool)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let info = list.first,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                           width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        guard frame.width > 1, frame.height > 1 else { return nil }
        let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        return (frame, onScreen)
    }
}
