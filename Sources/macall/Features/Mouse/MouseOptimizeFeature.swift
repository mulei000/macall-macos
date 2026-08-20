import AppKit
import CoreGraphics
import Foundation

// MARK: - 鼠标优化（滚轮反转 / 平滑滚动）
//
// 思路参考开源的 Mos / SmoothMouse：用单个 CGEventTap 拦截鼠标滚轮
// （scrollWheel），按子开关做轻量改写。
//
// 关键隔离设计（满足「默认全关、不影响其它功能」）：
//   · 单个功能 ↔ 单个 tap：install 时只建一次，uninstall 时彻底拆除并放行所有事件；
//   · 只有「功能总开关开 + 至少一个子功能开」时才真正创建 tap；子开关全关时
//     tap 不创建，事件原样透传，零侵入；
//   · 鼠标 / 触控板分流：按 MOS 的触控板判定（scrollPhase / momentumPhase /
//     scrollCount 任一非零即触控板）——比旧的 `isContinuous` 判定可靠：
//     罗技等鼠标也发 isContinuous=1，旧判定会漏判；触控板事件一律原样放行，绝不串味；
//   · 默认全部子开关关闭（mouseScrollInvert / mouseSmoothScroll 均 false），
//     即使用户开着总开关也完全不改滚动行为；
//   · 失败即 fail-closed：权限不足 / tap 创建失败 / 帧驱动不可用时只记日志、
//     不抛异常、不拦事件，其它功能（快捷键、分屏等）照常工作；
//   · 光标加速度：本功能**不**改系统参数，只提供「打开系统鼠标设置」按钮
//     （x-apple.systempreferences 跳转），与 SmoothMouse 的「关闭加速度」解耦。
//
// 平滑引擎（诉求：完全对齐 MOS 手感）：clean-room 移植 MOS 滚动算法，见
// MouseScrollEngine.swift —— 方向感知累积 + speed 倍率 + duration 指数缓动
// （k = 1-sqrt(duration/5.2)）+ 5 点曲线滤波去抖 + 死区停止 + CVDisplayLink
// 帧同步 + 合成事件标记（eventSourceUserData = 0x4D4F53534D4F4F54）防递归 +
// CGEventPostToPid 直投目标进程。
//
// 事件流：tap 收到真实滚轮 tick → 跳过合成事件 / 触控板放行 → 计算有效反转与
// 平滑 → 提取可用 delta（点 > 定点 > 整数）→ 反转 → step 归一 → 喂给
// MouseScrollEngine（引擎按帧合成投递）。不平滑时仅（可能）反转原样透传。

final class MouseOptimizeFeature: Feature {
    let id = "mouseOptimize"
    var title: String { IadenteL10n.t("鼠标优化", "Mouse Optimization") }
    var category: FeatureCategory { .system }
    var enabledByDefault: Bool { false }

    static var shared: MouseOptimizeFeature?

    private var config: Configuration = Configuration()

    /// MOS 风格平滑滚动引擎（clean-room 移植）。
    private let scrollEngine = MouseScrollEngine()

    // MARK: - 事件 tap

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Feature

    func install(context: AppContext) {
        self.config = context.config
        Self.shared = self
        syncEngineConfig()
        Log.info("[mouse] 已安装：鼠标优化就绪（按需创建拦截 tap）")
        syncTap()
    }

    func uninstall() {
        Self.shared = nil
        teardownTap()
        scrollEngine.reset()
        Log.info("[mouse] 已卸载，鼠标拦截停止")
    }

    func reload(config: Configuration) {
        self.config = config
        syncEngineConfig()
        syncTap()
    }

    func ensureTap() { syncTap() }
    func reenable() { syncTap() }

    func handle(action: String) {}

    /// 把当前配置的 MOS 三参数（step/speed/duration）同步给引擎。
    private func syncEngineConfig() {
        scrollEngine.configure(
            step: config.mouseScrollStep,
            speed: config.mouseScrollSpeed,
            duration: config.mouseScrollDuration,
            deadZone: 1.0 // MOS 默认死区
        )
    }

    // MARK: - tap 门控

    /// 是否真正需要拦截：总开关开 且 至少一个子功能开。
    private func wantsActive() -> Bool {
        config.isFeatureEnabled(id, default: enabledByDefault) &&
        (config.mouseScrollInvert || config.mouseSmoothScroll)
    }

    /// 按门控同步 tap：需要且未建 → 建；不需要且已建 → 拆。
    private func syncTap() {
        if wantsActive() {
            if tap == nil {
                installTap()
            }
        } else if tap != nil {
            teardownTap()
            scrollEngine.reset()
        }
    }

    // MARK: - 权限

    private func ensurePermission() -> Bool {
        guard Permissions.isAccessibilityWorking() else {
            Log.warning("[mouse] 缺少辅助功能权限，暂不创建鼠标拦截 tap，事件将透传")
            return false
        }
        return true
    }

    // MARK: - 事件拦截 tap

    private func installTap() {
        guard tap == nil else { return }
        guard ensurePermission() else { return }

        // 只监听滚轮（不拦侧键；inputMonitoring 不需要，仅辅助功能即可）。
        let mask: CGEventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passRetained(event)
            }
            let f = Unmanaged<MouseOptimizeFeature>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout {
                if let t = f.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return nil
            }
            // 引擎自己合成的平滑事件：直接放行，避免递归。
            if MouseScrollEngine.isSynthetic(event) {
                return Unmanaged.passRetained(event)
            }
            if type == .scrollWheel {
                return f.handleScroll(event)
            }
            return Unmanaged.passRetained(event)
        }

        guard let tap = CGEvent.tapCreate(
            // 对齐 MOS：用 session 注释层 + 链尾。HID 层（cghidEventTap）事件刚进系统，
            // eventTargetUnixProcessID 尚未解析（=0），合成事件将无法 postToPid 直投；
            // session 注释层事件已带目标进程信息，链尾修改最接近 App 接收点。
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
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
        Log.info("[mouse] 鼠标拦截 tap 已创建并启用（滚轮）")
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

    /// 返回被（可能）改写后的事件；返回 nil 表示「吃掉」该事件（由引擎用合成事件替代）。
    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 触控板事件（MOS 判定：scrollPhase / momentumPhase / scrollCount 任一非零）
        // 一律放行，避免与触控板手势调节串味。
        if Self.isTrackpad(event) {
            return Unmanaged.passRetained(event)
        }

        // 提取可用 delta（MOS 取法：点 > 定点 > 整数，取首个非零者）。
        let uy = Self.usableDelta(event, axis: 1)
        let ux = Self.usableDelta(event, axis: 2)
        guard uy != 0 || ux != 0 else {
            return Unmanaged.passRetained(event)
        }

        // 反转。
        let sy = config.mouseScrollInvert ? -uy : uy
        let sx = config.mouseScrollInvert ? -ux : ux

        // 平滑：step 归一后喂给引擎，吃掉原事件；引擎按帧合成投递。
        if config.mouseSmoothScroll {
            let ty = Self.normalizeToStep(sy, step: config.mouseScrollStep)
            let tx = Self.normalizeToStep(sx, step: config.mouseScrollStep)
            let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            let ok = scrollEngine.feed(usableY: ty, usableX: tx, targetPID: pid, baseEvent: event)
            if ok {
                return nil
            }
            // 引擎不可用（CVDisplayLink 失败）：fail-closed，原样透传（已含反转）。
            Log.warning("[mouse] 平滑引擎不可用，退回透传")
            if config.mouseScrollInvert {
                Self.setAllDeltas(event, y: sy, x: sx)
            }
            return Unmanaged.passRetained(event)
        }

        // 不平滑：仅（可能）反转，原样返回事件。
        if config.mouseScrollInvert {
            Self.setAllDeltas(event, y: sy, x: sx)
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: - 事件工具（MOS 语义）

    /// 触控板判定：scrollPhase / momentumPhase / scrollCount 任一非零即为触控板
    /// （比 isContinuous 可靠——罗技等鼠标也发 isContinuous=1）。
    private static func isTrackpad(_ event: CGEvent) -> Bool {
        let momentum = event.getDoubleValueField(.scrollWheelEventMomentumPhase)
        let scrollPhase = event.getDoubleValueField(.scrollWheelEventScrollPhase)
        let scrollCount = event.getDoubleValueField(.scrollWheelEventScrollCount)
        if momentum != 0 || scrollPhase != 0 {
            return true
        }
        return scrollCount != 0
    }

    /// 可用 delta 取法（MOS ScrollEvent.initEvent）：点 delta > 定点 delta > 整数 delta。
    private static func usableDelta(_ event: CGEvent, axis: Int) -> Double {
        let pt: Double
        let fixPt: Double
        let fix: Double
        if axis == 1 {
            pt = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            fixPt = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            fix = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        } else {
            pt = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            fixPt = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            fix = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        }
        if pt != 0 { return pt }
        if fixPt != 0 { return fixPt }
        return fix
    }

    /// step 归一（MOS ScrollEvent.normalize）：|value| 低于 step 时抬到 step，
    /// 保证一次滚轮 tick 也有足够能量进入缓冲（去抖 + 提速）。
    private static func normalizeToStep(_ value: Double, step: Double) -> Double {
        guard value != 0 else { return 0 }
        let mag = abs(value)
        let v = mag < step ? step : mag
        return value < 0 ? -v : v
    }

    /// 统一改写滚轮事件的 整数 / 定点 / 像素 三套 delta 表示，避免部分 App 读到旧值。
    private static func setAllDeltas(_ event: CGEvent, y: Double, x: Double) {
        let iy = Int64(y.rounded())
        let ix = Int64(x.rounded())
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: iy)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: ix)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: y)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: x)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
    }
}
