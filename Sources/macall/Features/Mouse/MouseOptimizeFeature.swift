import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 鼠标优化（滚轮反转 / 平滑滚动 / 侧键绑定 / 逐 App 例外）
//
// 思路参考开源的 Mos / SmoothMouse / MouseBridge：用单个 CGEventTap 拦截鼠标
// 滚轮（scrollWheel）与侧键（otherMouseDown），按子开关做轻量改写。
//
// 关键隔离设计（满足「默认全关、不影响其它功能」）：
//   · 单个功能 ↔ 单个 tap：install 时只建一次，uninstall 时彻底拆除并放行所有事件；
//   · 只有「功能总开关开 + 至少一个子功能开」时才真正创建 tap；子开关全关时
//     tap 不创建，事件原样透传，零侵入；
//   · 鼠标 / 触控板分流：用 `scrollWheelEventIsContinuous` 判定——触控板事件该位为 1
//     （连续事件），鼠标滚轮为 0（离散）。触控板事件一律原样放行，绝不串味；
//   · 默认全部子开关关闭（mouseScrollInvert / mouseSmoothScroll 均 false，
//     侧键绑定均为 none），即使用户开着总开关也完全不改滚动行为；
//   · 失败即 fail-closed：权限不足 / tap 创建失败时只记日志、不抛异常、不拦事件，
//     其它功能（快捷键、分屏等）照常工作；
//   · 光标加速度：本功能**不**改系统参数，只提供「打开系统鼠标设置」按钮
//     （x-apple.systempreferences 跳转），与 SmoothMouse 的「关闭加速度」解耦。
//
// 平滑引擎（诉求 3：原先只是 α=0.5 低通，不够顺）：改为带参数的惯性引擎——
//   最短步长 过滤生硬的小跳变（微动先累积、超过才刷新）；
//   速度增益 整体倍率（也可被「加速键」临时翻倍）；
//   平滑时长 决定惯性滑行尾迹的持续时间（越大越顺、滑行越久）。
// 引擎把每次真实 tick 的能量存进「蓄水池」，按比例逐帧（60Hz）放出，
// 总滚动量守恒（放出的和 = 收到的和），并在手势结束后把残量补发干净。

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

    // 参数化惯性引擎状态：蓄水池（尚未放出、待惯性补发的余量）。
    private var reservoirV: Double = 0
    private var reservoirH: Double = 0
    private var lastScrollTime: TimeInterval = 0
    private var momentumTimer: Timer?
    private var isEmitting = false
    /// 合成惯性事件打标，避免 tap 回调递归处理自己发出的事件。
    private let synthSource: CGEventSource? = CGEventSource(stateID: .combinedSessionState)
    /// 当前已建 tap 的 mask 是否包含侧键（otherMouseDown）。侧键绑定增删时需据此重建 tap。
    private var sideMaskActive = false

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
        (config.mouseScrollInvert ||
         config.mouseSmoothScroll ||
         config.mouseSideAction1 != .none ||
         config.mouseSideAction2 != .none)
    }

    /// 是否需要监听侧键（只有绑了动作才需要 otherMouseDown，也就只需「输入监控」权限）。
    private func needsSideMask() -> Bool {
        config.mouseSideAction1 != .none || config.mouseSideAction2 != .none
    }

    /// 按门控同步 tap：需要且未建 → 建；不需要且已建 → 拆；
    /// 已建但监听的事件类型变了（侧键绑定增删）→ 重建以更新 mask。
    private func syncTap() {
        if wantsActive() {
            if tap == nil {
                installTap()
            } else if sideMaskActive != needsSideMask() {
                teardownTap()
                stopMomentum()
                installTap()
            }
        } else if tap != nil {
            teardownTap()
            stopMomentum()
        }
    }

    // MARK: - 权限

    private func ensurePermission() -> Bool {
        guard Permissions.isAccessibilityWorking() else {
            Log.warning("[mouse] 缺少辅助功能权限，暂不创建鼠标拦截 tap，事件将透传")
            return false
        }
        // 仅滚轮反转 / 平滑只需要辅助功能即可；只有绑定了侧键（要拦截 otherMouseDown）
        // 才需要「输入监控」。避免用户没开输入监控就连滚轮都用不了。
        if needsSideMask(), !Permissions.inputMonitoringGranted {
            Log.warning("[mouse] 侧键绑定需要「输入监控」权限，暂不创建拦截 tap，事件将透传")
            return false
        }
        return true
    }

    // MARK: - 事件拦截 tap

    private func installTap() {
        guard tap == nil else { return }
        guard ensurePermission() else { return }

        // 监听：滚轮必监听；侧键（otherMouseDown）仅在绑定了动作时才纳入，
        // 这样「仅滚轮」场景只需辅助功能、不必要求输入监控。
        let wantSide = needsSideMask()
        var rawMask: UInt64 = 0
        rawMask |= UInt64(1) << CGEventType.scrollWheel.rawValue
        if wantSide {
            rawMask |= UInt64(1) << CGEventType.otherMouseDown.rawValue
        }
        let mask: CGEventMask = rawMask
        sideMaskActive = wantSide

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
            case .otherMouseDown:
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

    /// 返回被（可能）改写后的事件；返回 nil 表示「吃掉」该事件（由本功能用合成事件替代）。
    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 触控板事件（连续）一律放行，避免与触控板手势调节串味。
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        guard isContinuous == 0 else {
            return Unmanaged.passRetained(event)
        }

        // 当前前台 App 的 bundleID（用于逐 App 例外）。
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        // 计算该 App 的有效开关（全局 + 逐 App 三态覆盖）。
        let override = config.mouseAppOverrides[bundleID]
        var effSmooth = config.mouseSmoothScroll
        var effInvert = config.mouseScrollInvert
        if let override {
            switch override {
            case .smooth:    effSmooth = true
            case .invert:    effInvert = true
            }
        }

        let rawV = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let rawH = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let sign: Double = effInvert ? -1 : 1
        let signedV = Double(rawV) * sign
        let signedH = Double(rawH) * sign

        // 不平滑：仅（可能）反转，原样返回事件。
        guard effSmooth else {
            if effInvert {
                setScrollDelta(event, v: Int64(signedV.rounded()), h: Int64(signedH.rounded()))
            }
            return Unmanaged.passRetained(event)
        }

        // 平滑：把这次 tick 的能量（含速度增益）并入蓄水池，吃掉原事件，
        // 由惯性引擎逐帧放出（总滚动量守恒）。
        let gain = config.mouseSpeedGain
        let now = ProcessInfo.processInfo.systemUptime
        // 长间隔（>150ms）视为新一次滚动手势，先把上一轮的残量补发干净。
        if now - lastScrollTime > 0.15 {
            flushReservoir()
        }
        lastScrollTime = now

        reservoirV += signedV * gain
        reservoirH += signedH * gain

        pump()
        if abs(reservoirV) >= config.mouseMinStep || abs(reservoirH) >= config.mouseMinStep {
            startMomentum()
        }
        // 吃掉原事件；真正的滚动由 pump 投放的合成事件完成。
        return nil
    }

    // MARK: - 参数化惯性引擎

    /// 每帧放出的比例：由「平滑时长」推出，使蓄水池在约 smoothDuration 秒后衰减到约 1%。
    private func emitFraction() -> Double {
        let totalTicks = max(1.0, config.mouseSmoothDuration * 60.0)
        return 1.0 - pow(0.01, 1.0 / totalTicks)
    }

    /// 放出蓄水池的一部分（守恒：放出量 = 蓄水池减少量）。
    private func pump() {
        guard self.tap != nil else { return }
        let frac = emitFraction()
        let v = reservoirV * frac
        let h = reservoirH * frac
        reservoirV -= v
        reservoirH -= h
        // 残量很小：补发干净并停表，保证总滚动量不丢。
        if abs(reservoirV) < 0.5 && abs(reservoirH) < 0.5 {
            postSyntheticScroll(v: reservoirV, h: reservoirH)
            reservoirV = 0; reservoirH = 0
            stopMomentum()
            return
        }
        postSyntheticScroll(v: v, h: h)
    }

    /// 手势结束 / 重开时，把蓄水池里残余的能量一次性补发，避免丢滚动量。
    private func flushReservoir() {
        guard self.tap != nil else { reservoirV = 0; reservoirH = 0; return }
        if abs(reservoirV) > 0.001 || abs(reservoirH) > 0.001 {
            postSyntheticScroll(v: reservoirV, h: reservoirH)
        }
        reservoirV = 0; reservoirH = 0
        stopMomentum()
    }

    private func startMomentum() {
        guard momentumTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
        RunLoop.main.add(t, forMode: .common)
        momentumTimer = t
    }

    private func stopMomentum() {
        momentumTimer?.invalidate()
        momentumTimer = nil
    }

    /// 合成并投递一条滚轮事件（带 source 标记，回调里识别为自己发出的即放行）。
    private func postSyntheticScroll(v: Double, h: Double) {
        guard tap != nil else { return }
        guard let synth = CGEvent(source: synthSource) else { return }
        synth.type = .scrollWheel
        // 标记为「连续事件」：合成事件会重新进入同一个 tap，靠这个标记在回调里
        // 直接放行（guard isContinuous == 0 不成立），既避免递归平滑死循环，
        // 又让事件照常送达 App。
        synth.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
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

    // MARK: - 侧键处理（绑定 macall 动作）

    /// 侧键（X1=3 / X2=4）绑定 macall 动作：命中即派发，等价于按了对应快捷键；
    /// 派发成功则吃掉该侧键事件（避免 App 自己的前进/后退也触发）。未绑定则原样透传。
    private func handleSideButton(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        let action: MouseSideAction? = (btn == 3) ? config.mouseSideAction1
                               : (btn == 4) ? config.mouseSideAction2
                               : nil
        // [诊断] 无条件记录：原始按键号、解析到的绑定、是否命中（诉求 B 排查）。
        Log.info("[mouse][diag] 侧键事件 buttonNumber=\(btn) 解析动作=\(action?.rawValue ?? "nil") 命中=\(action != nil && action != .none)")
        guard let action, action != .none, let target = action.target else {
            return Unmanaged.passRetained(event)
        }
        // 派发走全局 FeatureRegistry（与快捷键同一路径），不合成键盘事件。
        // registry 未就绪时退回透传，避免白白吃掉点击。
        if let registry = context?.hotkeys.registry {
            registry.dispatch(featureId: target.feature, action: target.action)
            Log.info("[mouse] 侧键 \(btn == 3 ? "X1" : "X2") → 派发 \(target.feature)/\(target.action)")
            return nil
        }
        Log.warning("[mouse][diag] 侧键命中但 registry 未就绪，退回透传 buttonNumber=\(btn)")
        return Unmanaged.passRetained(event)
    }
}
