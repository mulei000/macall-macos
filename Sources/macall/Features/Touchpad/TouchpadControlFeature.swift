import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import Combine
import Foundation

// MARK: - 触控板手势调节（边缘滑入 → 拖动调亮度 / 音量）
//
// 思路参考 GitHub 上的两个开源项目：
//   · leecdiang/EdgeControl   —— 用鼠标移屏幕边缘 + 拖动来调亮度 / 音量；
//   · Zekilou/mac_touchpad    —— 用触控板手势 + 拖动来调亮度。
//
// 本功能复用 macall 已有的「动作层」（DDC 亮度 / CoreAudio 音量），只新建一层
// **触控板手势输入层**：通过私有框架 MultitouchSupport 拿到逐指接触帧，识别
// 「边缘滑入」手势，按住时按手指垂直位移相对调节亮度或音量。
//
// 设计要点：
//   · 唯一触发方式「边缘滑入」：手指必须从最外侧起手（起手区默认最外 6%，防「靠近边缘就误触」）、
//     向内滑动超过向内行程阈值（默认 0.15）且以横向滑动为主（向内位移 ≥ 垂直位移；
//     正常滚动是垂直的）才锁定调节态，上下拖动即相对调节，抬起结束。比双击更自然，
//     也不容易被正常滚动误触发。起手区与向内行程均可在设置页自定义，方便调到舒适范围。
//   · 左右边缘映射可配置：左 → 亮度（默认）、右 → 音量（默认），也可各自设为 off。
//   · 调节过程支持「逐级触觉」：数值每跨越约 2% 给一次轻微「咔哒」反馈（可在设置关闭）。
//   · 上下拖动灵敏度、起手区、向内行程均可在设置页自定义
//     （touchpadSensitivity / touchpadStartZone / touchpadMinTravel）。
//   · 私有框架用 dlopen / dlsym 动态桥接（与项目里 DDC.swift、PrivateAPI.swift 同范式），
//     任何一步失败都「fail-closed」：只记日志、不影响 app 其余部分。
//
// 私有框架脆弱性声明：MultitouchSupport 是 Apple 私有框架，MTTouch 的内存布局
// 随 macOS / 机型可能变化。本实现采用 macOS 15 / macOS 26 (Tahoe) 下实测一致的 96 字节布局
// （state@+20、pathIndex@+16、normX@+32、normY@+36，已在用户本机 macOS 26 诊断帧确认）。

final class TouchpadControlFeature: Feature {
    let id = "touchpadControl"
    var title: String { IadenteL10n.t("触控板调节亮度/音量", "Trackpad Brightness/Volume") }
    var category: FeatureCategory { .system }
    var enabledByDefault: Bool { false }

    static var shared: TouchpadControlFeature?

    private var context: AppContext?
    private var config: Configuration = Configuration()

    // MARK: - 私有框架桥接状态

    private var dlHandle: UnsafeMutableRawPointer?
    private var stopFn: MTDeviceStopFn?
    private var deviceList: CFMutableArray?
    private var startedDevices: [UnsafeMutableRawPointer] = []
    private var isSetup = false

    // MARK: - 手势状态机

    private enum GState { case idle, holding }
    private enum EdgeSide { case left, right }

    private struct FingerTrack {
        var downTime: TimeInterval = 0
        var downX: Float = 0
        var downY: Float = 0
        var lastX: Float = 0
        var lastY: Float = 0
        var maxMove: Float = 0
        var side: EdgeSide? = nil   // 起手边（边缘滑入：仅最外缘起手才有效）
        var armed = false           // 边缘滑入：是否已滑过阈值锁定调节
        var lifted = false
    }

    // 手势参数：灵敏度 / 起手区 / 向内行程均为设置页可自定义项（读 config.touchpad*），
    // 其余为经验常量。
    private let applyThreshold: Float = 0.005     // 变化超过该值才真正下发，避免高频抖动
    private let hapticStep: Float = 0.02          // 逐级触觉：每跨越约 2% 给一次「咔哒」反馈
    private static let mtTouchStride = 96         // 单个 MTTouch 结构体字节长度（macOS 15/26 实测一致）

    private var gState: GState = .idle
    private var holdPath: Int32 = -1
    private var holdStartY: Float = 0
    private var holdAnchor: Float = 0.5
    private var holdAction: TouchpadEdgeAction = .brightness
    private var holdBeginTime: TimeInterval = 0
    private var lastApplied: Float = 0.5
    private var lastHapticStep: Int = 0
    private var fingers: [Int32: FingerTrack] = [:]

    // MARK: - HUD

    private let hudModel = TouchpadHUDModel()
    private var hudPanel: TouchpadHUDPanel?
    private var hudHosting: NSHostingController<TouchpadHUDView>?

    // MARK: - Feature

    func install(context: AppContext) {
        self.context = context
        self.config = context.config
        Self.shared = self
        // 仅在功能被启用时才注册私有框架触控回调；默认关闭时不注册，避免启动/误触触发崩溃。
        syncBridge()
        Log.info("[touchpad] 已安装：触控板手势调节就绪")
    }

    func uninstall() {
        Self.shared = nil
        teardownMultitouch()
        resetGesture()
        hideHUD()
        Log.info("[touchpad] 已卸载，触控监听停止")
    }

    func reload(config: Configuration) {
        self.config = config
        // 用户在设置页开启 / 关闭本功能并保存时，由 registry.reloadAll() 触发这里。
        syncBridge()
    }

    func ensureTap() {
        // 权限（辅助功能 / 输入监控）可能在启动后才授予；按当前启用状态同步桥接。
        syncBridge()
    }

    func reenable() {
        syncBridge()
    }

    /// 按启用状态门控私有框架回调：启用且未建 → 建；禁用且已建 → 拆。
    private func syncBridge() {
        let want = config.isFeatureEnabled(id, default: enabledByDefault)
        if want, !isSetup {
            setupMultitouch()
        } else if !want, isSetup {
            teardownMultitouch()
            resetGesture()
        }
    }

    func handle(action: String) {}

    // MARK: - 私有框架桥接

    private func setupMultitouch() {
        guard !isSetup else { return }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            Log.error("[touchpad] 无法加载 MultitouchSupport.framework（私有框架缺失或受限）")
            return
        }
        guard let createSym = dlsym(handle, "MTDeviceCreateList"),
              let regSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop") else {
            Log.error("[touchpad] 无法解析 MultitouchSupport 符号（框架版本不匹配）")
            dlclose(handle)
            return
        }
        let createList = unsafeBitCast(createSym, to: MTDeviceCreateListFn.self)
        let registerCb = unsafeBitCast(regSym, to: MTRegisterContactFrameCallbackFn.self)
        let startDev = unsafeBitCast(startSym, to: MTDeviceStartFn.self)
        let stopDev = unsafeBitCast(stopSym, to: MTDeviceStopFn.self)

        guard let unmanaged = createList() else {
            Log.error("[touchpad] MTDeviceCreateList 返回空")
            dlclose(handle)
            return
        }
        let list = unmanaged.takeRetainedValue()
        let count = CFArrayGetCount(list)
        let callback: MTContactFrameCallback = touchpadContactFrameCallback
        for i in 0..<count {
            guard let elem = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: elem)
            registerCb(device, callback)
            startDev(device, 0)
            startedDevices.append(device)
        }
        dlHandle = handle
        stopFn = stopDev
        deviceList = list
        isSetup = true
        Log.info("[touchpad] MultitouchSupport 桥接成功，监听 \(startedDevices.count) 个触控设备")
    }

    private func teardownMultitouch() {
        for d in startedDevices { stopFn?(d) }
        startedDevices.removeAll()
        if let h = dlHandle { dlclose(h); dlHandle = nil }
        stopFn = nil
        deviceList = nil
        isSetup = false
    }

    // MARK: - 接触帧回调（运行在 MultitouchSupport 内部线程）

    func processFrame(
        touches: UnsafeRawPointer,
        nFingers: Int32,
        timestamp: Double
    ) {
        // 防御：私有框架回调一旦传入异常 nFingers 直接退出，绝不做越界访问。
        guard nFingers > 0, nFingers <= 64 else { return }

        var seen = Set<Int32>()
        for i in 0..<Int(nFingers) {
            // touches 是「连续的 MTTouch 结构体数组」（MTTouch*），按 stride 逐指推进。
            let tp = touches.advanced(by: i * Self.mtTouchStride)
            let state = tp.load(fromByteOffset: 20, as: Int32.self)
            let path = tp.load(fromByteOffset: 16, as: Int32.self)
            let nx = tp.load(fromByteOffset: 32, as: Float32.self)
            let ny = tp.load(fromByteOffset: 36, as: Float32.self)
            seen.insert(path)

            if state >= 3, state <= 5 {
                // 手指落下 / 移动中。
                if var t = fingers[path] {
                    t.lastX = nx; t.lastY = ny
                    t.maxMove = max(t.maxMove, hypot(nx - t.downX, ny - t.downY))
                    fingers[path] = t
                } else {
                    // 新手指落下：若已在调节中，第二指落下 → 取消，防多指误调。
                    if gState == .holding { endHold() }
                    let side = swipeSideOf(nx)
                    fingers[path] = FingerTrack(
                        downTime: timestamp, downX: nx, downY: ny,
                        lastX: nx, lastY: ny, side: side, armed: false)
                }
                // 边缘滑入：必须从最外缘起手、向内滑过阈值且以横向为主
                // （向内位移 ≥ 垂直位移，正常滚动是垂直的）才锁定调节，防误触。
                if gState == .idle,
                   let t = fingers[path], let s = t.side, !t.armed,
                   inwardTravel(t) >= Float(config.touchpadMinTravel),
                   inwardTravel(t) >= abs(t.lastY - t.downY) {
                    var nt = t; nt.armed = true; fingers[path] = nt
                    beginHold(path: path, action: actionFor(s), startY: nt.lastY, t: timestamp)
                }
            } else if state == 7 || state == 0 {
                // 手指抬起 / 消失。
                if let t = fingers[path], !t.lifted {
                    var nt = t; nt.lifted = true; fingers[path] = nt
                    if gState == .holding, path == holdPath { endHold() }
                }
            }
        }

        // 清理已经不在接触帧里的手指。
        for path in fingers.keys where !seen.contains(path) {
            fingers.removeValue(forKey: path)
        }

        // 保持态：按垂直位移相对调节。
        if gState == .holding {
            if let ht = fingers[holdPath] {
                applyHold(currentY: ht.lastY, t: timestamp)
            } else {
                endHold()
            }
        }
    }

    // MARK: - 手势状态机（仅边缘滑入）

    private func beginHold(path: Int32, action: TouchpadEdgeAction, startY: Float, t: TimeInterval) {
        guard action != .off else { resetGesture(); return }
        holdPath = path
        holdStartY = startY
        holdAction = action
        holdBeginTime = t
        holdAnchor = currentValue(action)
        lastApplied = holdAnchor
        // 以当前值为基准对齐触觉台阶，避免起手就多响一次。
        lastHapticStep = Int((holdAnchor / hapticStep).rounded())
        gState = .holding
        performHaptic()
        showHUD(action: action)
        updateHUD(value: holdAnchor)
    }

    private func applyHold(currentY: Float, t: TimeInterval) {
        // 触控板归一坐标 y 向上增大；手指上移 → 值增大。灵敏度取自设置项。
        let sensitivity = Float(config.touchpadSensitivity)
        let delta = (currentY - holdStartY) * sensitivity
        let newVal = min(1, max(0, holdAnchor + delta))
        if abs(newVal - lastApplied) >= applyThreshold {
            lastApplied = newVal
            applyValue(holdAction, newVal)
            updateHUD(value: newVal)
        }
        // 逐级触觉：每跨越 hapticStep 给一次「咔哒」反馈。
        if config.touchpadHaptic {
            let step = Int((newVal / hapticStep).rounded())
            if step != lastHapticStep {
                lastHapticStep = step
                performHaptic()
            }
        }
    }

    private func endHold() {
        gState = .idle
        holdPath = -1
        hideHUD()
    }

    private func resetGesture() {
        gState = .idle
        holdPath = -1
        hideHUD()
    }

    /// 边缘滑入起手边：必须从最外 touchpadStartZone 起手（设置页可自定义）。
    private func swipeSideOf(_ x: Float) -> EdgeSide? {
        let zone = Float(config.touchpadStartZone)
        if x < zone { return .left }
        if x > 1 - zone { return .right }
        return nil
    }

    /// 手指自起手点向中心（内）滑动的归一化距离。
    private func inwardTravel(_ t: FingerTrack) -> Float {
        guard let side = t.side else { return 0 }
        switch side {
        case .left: return t.lastX - t.downX   // 左缘：x 增大 = 向右（内）滑
        case .right: return t.downX - t.lastX  // 右缘：x 减小 = 向左（内）滑
        }
    }

    private func actionFor(_ side: EdgeSide) -> TouchpadEdgeAction {
        switch side {
        case .left: return config.touchpadLeftAction
        case .right: return config.touchpadRightAction
        }
    }

    // MARK: - 动作层（复用 DDC / CoreAudio）

    private func currentValue(_ action: TouchpadEdgeAction) -> Float {
        switch action {
        case .brightness: return DDC.getBrightness(display: CGMainDisplayID()) ?? 0.5
        case .volume: return VolumeCore.getVolume() ?? 0.5
        case .off: return 0.5
        }
    }

    private func applyValue(_ action: TouchpadEdgeAction, _ v: Float) {
        let c = min(1, max(0, v))
        DispatchQueue.main.async {
            switch action {
            case .brightness: _ = DDC.setBrightness(display: CGMainDisplayID(), level: c)
            case .volume: VolumeCore.setVolume(c)
            case .off: break
            }
        }
    }

    private func performHaptic() {
        guard config.touchpadHaptic else { return }
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    // MARK: - HUD

    private func showHUD(action: TouchpadEdgeAction) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hudModel.action = action
            if self.hudPanel == nil {
                let ctrl = NSHostingController(rootView: TouchpadHUDView(model: self.hudModel))
                ctrl.view.wantsLayer = true
                ctrl.view.layer?.cornerRadius = 14
                ctrl.view.layer?.masksToBounds = true
                let p = TouchpadHUDPanel(contentViewController: ctrl)
                p.styleMask = [.borderless, .nonactivatingPanel]
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hasShadow = true
                p.level = .floating
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                p.hidesOnDeactivate = false
                p.isReleasedWhenClosed = false
                p.animationBehavior = .none
                self.hudPanel = p
                self.hudHosting = ctrl
            }
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let w: CGFloat = 200, h: CGFloat = 150
                let visible = screen.visibleFrame
                let x = visible.midX - w / 2
                let y = visible.maxY - h - 40
                self.hudPanel?.setFrame(
                    NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h), display: false)
            }
            self.hudPanel?.orderFrontRegardless()
        }
    }

    private func updateHUD(value: Float) {
        DispatchQueue.main.async { [weak self] in self?.hudModel.value = value }
    }

    private func hideHUD() {
        DispatchQueue.main.async { [weak self] in self?.hudPanel?.orderOut(nil) }
    }
}

// MARK: - 私有框架 C 类型

private typealias MTContactFrameCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeRawPointer,
    Int32,
    Double,
    Int32
) -> Void

private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
private typealias MTRegisterContactFrameCallbackFn = @convention(c) (
    UnsafeMutableRawPointer?,
    MTContactFrameCallback
) -> Void
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// 接触帧回调：转发到当前 TouchpadControlFeature 单例。
private func touchpadContactFrameCallback(
    _ device: UnsafeMutableRawPointer?,
    _ touches: UnsafeRawPointer,
    _ nFingers: Int32,
    _ timestamp: Double,
    _ frame: Int32
) {
    TouchpadControlFeature.shared?.processFrame(
        touches: touches, nFingers: nFingers, timestamp: timestamp)
}

// MARK: - HUD 视图

final class TouchpadHUDModel: ObservableObject {
    @Published var value: Float = 0.5
    @Published var action: TouchpadEdgeAction = .brightness
}

private final class TouchpadHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct TouchpadHUDView: View {
    @ObservedObject var model: TouchpadHUDModel

    private var icon: String {
        switch model.action {
        case .brightness: return "sun.max.fill"
        case .volume: return "speaker.wave.2.fill"
        case .off: return "xmark.circle.fill"
        }
    }

    private var label: String {
        switch model.action {
        case .brightness: return IadenteL10n.t("亮度", "Brightness")
        case .volume: return IadenteL10n.t("音量", "Volume")
        case .off: return IadenteL10n.t("关闭", "Off")
        }
    }

    var body: some View {
        ZStack {
            IadenteWindowBackdrop()
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(IadenteTheme.dashboardColors.first ?? .accentColor)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text("\(Int(model.value * 100))%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(IadenteTheme.dashboardColors.first ?? .accentColor)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(IadenteTheme.dashboardColors.first ?? .accentColor)
                            .frame(width: geo.size.width * CGFloat(model.value))
                    }
                    .frame(height: 8)
                }
                .frame(height: 8)
            }
            .padding(18)
            .frame(width: 200)
        }
    }
}
