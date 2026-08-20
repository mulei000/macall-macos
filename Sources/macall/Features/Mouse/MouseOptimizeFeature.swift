import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 鼠标优化（滚轮反转 / 平滑滚动 / 侧键互换）
//
// 思路参考开源的 Mos / MouseBridge / SmoothMouse：用单个 CGEventTap 拦截鼠标
// 滚轮（scrollWheel）与侧键（otherMouseDown/Up），按子开关做轻量改写。
//
// 关键隔离设计（满足「默认全关、不影响其它功能」）：
//   · 单个功能 ↔ 单个 tap：install 时只建一次，uninstall 时彻底拆除并放行所有事件；
//   · 只有「功能总开关开 + 至少一个子开关开」时才真正创建 tap；子开关全关时
//     tap 不创建，事件原样透传，零侵入；
//   · 鼠标 / 触控板分流：用 `scrollWheelEventIsContinuous` 判定——触控板事件该位为 1
//     （连续事件），鼠标滚轮为 0（离散）。触控板事件一律原样放行，绝不串味；
//   · 默认全部子开关关闭（mouseScrollInvert / mouseSmoothScroll / mouseSideButtonSwap
//     均 false，平滑模式默认 light），即使用户开着总开关也完全不改动滚动行为；
//   · 失败即 fail-closed：权限不足 / tap 创建失败时只记日志、不抛异常、不拦事件，
//     其它功能（快捷键、分屏等）照常工作；
//   · 光标加速度：本功能**不**改系统参数，只提供「打开系统鼠标设置」按钮
//     （x-apple.systempreferences 跳转），与 SmoothMouse 的「关闭加速度」解耦。

final class MouseOptimizeFeature: Feature {
    let id = "mouseOptimize"
    var title: String { IadenteL10n.t("鼠标优化", "Mouse Optimization") }
    var category: FeatureCategory { .system }
    var enabledByDefault: Bool { false }

    static var shared: MouseOptimizeFeature?

    private var context: AppContext?
    private var config: Configuration = Configuration()

    // MARK: - 事件 tap

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // 平滑（轻量低通）状态：区分连续手势，长间隔后复位。
    private var lastScrollTime: TimeInterval = 0
    private var smoothedV: Double = 0
    private var smoothedH: Double = 0

    // 完整惯性：缓冲 + 衰减尾迹。
    private var momentumBufferV: Double = 0
    private var momentumBufferH: Double = 0
    private var momentumTimer: Timer?
    private var momentumStart: TimeInterval = 0
    private var isEmitting = false
    /// 合成惯性事件打标，避免 tap 回调递归处理自己发出的事件。
    private let synthSource: CGEventSource? = CGEventSource(stateID: .combinedSessionState)

    // MARK: - Feature

    func install(context: AppContext) {
        self.context = context
        self.config = context.config
        Self.shared = self
        Log.info("[mouse] 已安装：鼠标优化就绪（按需创建拦截 tap）")
        syncTap()
    }

    func uninstall() {
        Self.shared = nil
        teardownTap()
        stopMomentum()
        Log.info("[mouse] 已卸载，鼠标拦截停止")
    }

    func reload(config: Configuration) {
        self.config = config
        syncTap()
    }

    func ensureTap() { syncTap() }
    func reenable() { syncTap() }

    func handle(action: String) {}

    // MARK: - tap 门控

    /// 是否真正需要拦截：总开关开 且 至少一个子功能开。
    private func wantsActive() -> Bool {
        config.isFeatureEnabled(id, default: enabledByDefault) &&
        (config.mouseScrollInvert || config.mouseSmoothScroll || config.mouseSideButtonSwap)
    }

    /// 按门控同步 tap：需要且未建 → 建；不需要且已建 → 拆。
    private func syncTap() {
        if wantsActive(), tap == nil {
            installTap()
        } else if !wantsActive(), tap != nil {
            teardownTap()
            stopMomentum()
        }
    }

    // MARK: - 权限

    private func ensurePermission() -> Bool {
        let ax = Permissions.isAccessibilityWorking()
        let input = Permissions.inputMonitoringGranted
        guard ax, input else {
            Log.warning("[mouse] 缺少权限（辅助功能=\(ax) 输入监控=\(input)），暂不创建滚轮 tap，事件将透传")
            return false
        }
        return true
    }

    // MARK: - 事件拦截 tap

    private func installTap() {
        guard tap == nil else { return }
        guard ensurePermission() else { return }

        // 监听：滚轮 + 侧键按下/抬起。拆成子表达式避免整条 CGEventMask 触发类型检查超时。
        var rawMask: UInt64 = 0
        rawMask |= UInt64(1) << CGEventType.scrollWheel.rawValue
        rawMask |= UInt64(1) << CGEventType.otherMouseDown.rawValue
        rawMask |= UInt64(1) << CGEventType.otherMouseUp.rawValue
        let mask: CGEventMask = rawMask

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passRetained(event)
            }
            let f = Unmanaged<MouseOptimizeFeature>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout {
                if let t = f.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return nil
            }
            // 自己发出的惯性事件：直接放行，避免递归。
            if f.isEmitting { return Unmanaged.passRetained(event) }
            switch type {
            case .scrollWheel:
                return f.handleScroll(event)
            case .otherMouseDown, .otherMouseUp:
                return f.handleSideButton(event)
            default:
                return Unmanaged.passRetained(event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Log.error("[mouse] 无法创建鼠标拦截 tap（权限不足或被占用）")
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("[mouse] 鼠标拦截 tap 已创建并启用（滚轮 + 侧键）")
    }

    private func teardownTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    // MARK: - 滚轮处理

    /// 返回被（可能）改写后的事件；原件原样返回即透传。
    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 触控板事件（连续）一律放行，避免与触控板手势调节串味。
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        guard isContinuous == 0 else {
            return Unmanaged.passRetained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        // 长间隔（>150ms）视为新一次滚动手势，复位平滑状态。
        if now - lastScrollTime > 0.15 {
            smoothedV = 0; smoothedH = 0
            momentumBufferV = 0; momentumBufferH = 0
            stopMomentum()
        }
        lastScrollTime = now

        // 原始 delta（整数 / 定点 / 像素三套表示都读出来再分别改写）。
        let rawV = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let rawH = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)

        // 反转（影响后续所有计算：先把符号翻转）。
        let sign: Double = config.mouseScrollInvert ? -1 : 1
        let rV = Double(rawV) * sign
        let rH = Double(rawH) * sign

        guard config.mouseSmoothScroll else {
            // 仅反转、不平滑：直接把原事件三套 delta 取反后返回。
            if config.mouseScrollInvert {
                setScrollDelta(event, v: Int64(rV.rounded()), h: Int64(rH.rounded()))
            }
            return Unmanaged.passRetained(event)
        }

        if config.mouseSmoothMode == .light {
            // 轻量低通：平滑抖动，不改变总量（每 tick 透传滤波后的值）。
            let alpha = 0.5
            smoothedV = smoothedV * alpha + rV * (1 - alpha)
            smoothedH = smoothedH * alpha + rH * (1 - alpha)
            setScrollDelta(event, v: Int64(smoothedV.rounded()), h: Int64(smoothedH.rounded()))
            return Unmanaged.passRetained(event)
        } else {
            // 完整惯性：当场只放一部分，余量进缓冲，由定时器衰减补发，形成滑行。
            let holdRatio = 0.3
            let immediateV = rV * (1 - holdRatio)
            let immediateH = rH * (1 - holdRatio)
            momentumBufferV += rV * holdRatio
            momentumBufferH += rH * holdRatio
            setScrollDelta(event, v: Int64(immediateV.rounded()), h: Int64(immediateH.rounded()))
            if abs(momentumBufferV) > 0.5 || abs(momentumBufferH) > 0.5 {
                startMomentum()
            }
            return Unmanaged.passRetained(event)
        }
    }

    /// 统一改写滚轮事件的 整数 / 定点 / 像素 三套 delta 表示，避免部分 App 读到旧值。
    private func setScrollDelta(_ event: CGEvent, v: Int64, h: Int64) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: v)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: h)
        // 定点（fixed-point）与像素（point）表示同步取反，保证 Chrome/Safari 等读像素 delta 的 App 也正确。
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(v))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(h))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: v)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: h)
    }

    // MARK: - 完整惯性尾迹

    private func startMomentum() {
        guard momentumTimer == nil else { return }
        momentumStart = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.emitMomentumTick()
        }
        RunLoop.main.add(t, forMode: .common)
        momentumTimer = t
    }

    private func emitMomentumTick() {
        // 安全边界：最多补发 400ms；低于阈值即停，绝不无限滚动。
        let now = ProcessInfo.processInfo.systemUptime
        guard now - momentumStart < 0.4 else { stopMomentum(); return }
        let decay = 0.78
        let v = momentumBufferV * 0.25
        let h = momentumBufferH * 0.25
        momentumBufferV *= decay
        momentumBufferH *= decay
        if abs(momentumBufferV) < 0.5 && abs(momentumBufferH) < 0.5 {
            momentumBufferV = 0; momentumBufferH = 0
            stopMomentum()
            return
        }
        postSyntheticScroll(v: v, h: h)
    }

    /// 合成并投递一条滚轮事件（带 source 标记，回调里识别为自己发出的即放行）。
    private func postSyntheticScroll(v: Double, h: Double) {
        guard tap != nil else { return }
        guard let synth = CGEvent(source: synthSource) else { return }
        synth.type = .scrollWheel
        synth.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(v.rounded()))
        synth.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(h.rounded()))
        synth.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: v)
        synth.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: h)
        synth.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(v.rounded()))
        synth.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(h.rounded()))
        isEmitting = true
        synth.post(tap: .cghidEventTap)
        isEmitting = false
    }

    private func stopMomentum() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumBufferV = 0
        momentumBufferH = 0
    }

    // MARK: - 侧键处理

    /// 侧键互换（X1 后退 ↔ X2 前进）。非侧键事件原样返回。
    private func handleSideButton(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard config.mouseSideButtonSwap else {
            return Unmanaged.passRetained(event)
        }
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        if btn == 3 { // X1（后退）
            event.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        } else if btn == 4 { // X2（前进）
            event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        }
        return Unmanaged.passRetained(event)
    }
}
