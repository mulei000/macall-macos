import AppKit
import ApplicationServices
import CoreGraphics
import CoreVideo
import Foundation

// MARK: - 鼠标平滑滚动引擎（clean-room 移植 MOS 算法）
//
// 仅移植 MOS 的「滚动引擎算法」，不拷贝其源码（MOS 为 CC BY-NC 4.0，与 macall
// GPL-3.0 不兼容）；以下为基于 MOS 数学用 macall 自有代码重新实现，版权零风险。
//
// 关键算法（与 MOS ScrollPoster / Interpolator / ScrollFilter 行为一致）：
//   · 方向感知累积：每次真实 tick 把能量按 speed 倍率送进 buffer。同向累加；
//     反向则重置该轴 buffer 与 current（MOS ScrollPoster.update 行为）。
//   · 显示帧同步：用 CVDisplayLink 驱动每帧 processing()，与屏幕刷新同频，
//     避免旧 60Hz 定时器在负载下掉帧导致的卡顿（MOS 同款做法）。
//   · 指数缓动：每帧 frame = (buffer - current) * k，current += frame，
//     k = durationTransition = 1 - sqrt(duration / 5.2)
//     （MOS 默认 duration=4.35 → k≈0.085）。
//   · 曲线滤波：5 点窗（MOS ScrollFilter.polish）去除起始抖动，输出延迟约 4 帧。
//   · 死区停止：输出幅值 < deadZone 且已收敛即停止 CVDisplayLink，并发送收尾零点事件。
//   · 合成事件标记：写 eventSourceUserData = 0x4D4F53534D4F4F54，
//     tap 回调据此跳过自身事件，避免递归平滑死循环（比依赖 isContinuous 更稳健）。
//   · 直投目标进程：CGEventPostToPid 投到原始事件的目标 PID，动量不跟随光标、
//     不经过 tap 链重路由（MOS #523 / #868 方案）。
//
// 线程模型：feed() 在 tap 回调（主线程）调用；processing() 在 CVDisplayLink 线程
// 调用；两者通过 NSLock 保护共享状态。回调体用 MACatchException 包裹，防 ObjC
// 异常静默拖垮整个 App（与本项目事件 tap 的容错约定一致）。

final class MouseScrollEngine {

    // MARK: 合成事件标记（与 MOS 完全一致，用于 tap 回调识别并跳过自身事件）

    static let syntheticMarker: Int64 = 0x4D4F53534D4F4F54

    static func isSynthetic(_ event: CGEvent) -> Bool {
        return event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }

    static func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    }

    // MARK: 配置快照（configure 写入，processing 只读）

    private struct Config {
        var step: Double = 33.6
        var speed: Double = 2.70
        var k: Double = 0.085 // durationTransition
        var deadZone: Double = 1.0
    }
    private var config = Config()

    // MARK: 滚动状态

    private var current = (y: 0.0, x: 0.0) // 已发出的位置
    private var delta = (y: 0.0, x: 0.0) // 上一次方向样本
    private var buffer = (y: 0.0, x: 0.0) // 目标缓冲（方向感知累积）
    private var curveY = [0.0, 0.0] // 曲线滤波窗（MOS 初值 [0,0]）
    private var curveX = [0.0, 0.0]

    // 输入节奏追踪（MOS 同款阈值）
    private let manualContinuationThreshold: CFTimeInterval = 0.18
    private let momentumEndDelay: CFTimeInterval = 0.13
    private var lastManualEventTime: CFTimeInterval = 0.0
    private var manualInputEnded = true
    private var momentumActive = false
    private var momentumEndScheduledTime: CFTimeInterval? = nil

    // 目标进程与事件模板（合成事件复用其元数据 + 目标 PID）
    private var targetPID: pid_t = 0
    private var baseEvent: CGEvent? = nil

    // 帧驱动
    private var displayLink: CVDisplayLink?
    private var linkRunning = false
    private let lock = NSLock()

    // MARK: - 配置

    func configure(step: Double, speed: Double, duration: Double, deadZone: Double) {
        lock.lock()
        config.step = max(0.0, step)
        config.speed = max(0.0, speed)
        // durationTransition = 1 - sqrt(duration / 5.2)（与 MOS 完全一致）
        let d = max(0.1, duration)
        var k = 1.0 - (d / 5.2).squareRoot()
        k = min(0.95, max(0.005, k))
        config.k = k
        config.deadZone = max(0.0, deadZone)
        lock.unlock()
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return displayLink != nil
    }

    // MARK: - 接收一次真实滚动 tick
    // usableY / usableX 为「已按逐 App 反转、已 step 归一」的可用 delta（尚未乘 speed）。
    // 返回 false 表示帧驱动不可用（fail-closed，调用方应原样透传事件）。

    @discardableResult
    func feed(usableY: Double, usableX: Double, targetPID: pid_t, baseEvent: CGEvent) -> Bool {
        lock.lock()

        // 捕获本次事件模板与目标 PID（合成事件复用其元数据 + 目标）。
        self.targetPID = targetPID
        self.baseEvent = baseEvent.copy()

        // 方向感知累积：同向累加，反向重置该轴 buffer 与 current（MOS 行为）。
        if usableY * delta.y > 0 {
            buffer.y += usableY * config.speed
        } else {
            buffer.y = usableY * config.speed
            current.y = 0.0
        }
        if usableX * delta.x > 0 {
            buffer.x += usableX * config.speed
        } else {
            buffer.x = usableX * config.speed
            current.x = 0.0
        }
        delta = (y: usableY, x: usableX)

        let now = CFAbsoluteTimeGetCurrent()
        lastManualEventTime = now
        manualInputEnded = false
        momentumActive = false
        momentumEndScheduledTime = nil

        ensureLinkLocked()
        let ok = displayLink != nil
        lock.unlock()
        return ok
    }

    // MARK: - 帧处理（CVDisplayLink 回调，后台线程）

    private func processing() {
        MACatchException {
            self._processingLocked()
        }
    }

    private func _processingLocked() {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let k = config.k
        let deadZone = config.deadZone

        // 帧插值（指数缓动）
        let frameY = (buffer.y - current.y) * k
        let frameX = (buffer.x - current.x) * k
        current.y += frameY
        current.x += frameX

        // 曲线滤波去抖（输出延迟约 4 帧）
        let filled = (
            y: fillCurve(&curveY, next: frameY),
            x: fillCurve(&curveX, next: frameX)
        )

        // 手动输入结束判定（超过 continuation 阈值视为手势结束，转入惯性）
        if !manualInputEnded && lastManualEventTime > 0 && now - lastManualEventTime > manualContinuationThreshold {
            manualInputEnded = true
        }

        // 残差与动量状态机
        let residualY = buffer.y - current.y
        let residualX = buffer.x - current.x
        let residualMagnitude = max(residualY.magnitude, residualX.magnitude)

        if manualInputEnded && residualMagnitude > deadZone {
            momentumActive = true
            momentumEndScheduledTime = nil
        } else if momentumActive && residualMagnitude <= deadZone {
            if momentumEndScheduledTime == nil {
                momentumEndScheduledTime = now + momentumEndDelay
            }
        } else {
            momentumEndScheduledTime = nil
            momentumActive = false
        }

        // 发送：仅当输出幅值超过死区才发（避免发送亚像素抖动）
        let outputMagnitude = max(filled.y.magnitude, filled.x.magnitude)
        var shouldStop = false
        if outputMagnitude > deadZone {
            post(v: filled)
        } else if manualInputEnded && !momentumActive && residualMagnitude <= deadZone {
            // 已收敛：发一个收尾零点事件并停止链路。
            post(v: (y: 0, x: 0))
            shouldStop = true
        }

        if let scheduled = momentumEndScheduledTime, momentumActive, now >= scheduled {
            momentumEndScheduledTime = nil
            momentumActive = false
            post(v: (y: 0, x: 0))
            shouldStop = true
        }

        lock.unlock()

        if shouldStop {
            stopLink()
        }
    }

    // 5 点曲线窗（MOS ScrollFilter.polish，行为一致）
    private func fillCurve(_ window: inout [Double], next: Double) -> Double {
        let first = window[1]
        let diff = next - first
        window = [first, first + 0.23 * diff, first + 0.5 * diff, first + 0.77 * diff, next]
        return window[0]
    }

    // MARK: - 投递合成事件到目标进程

    /// 目标 PID 无效时是否已打过回退日志（节流，避免每帧刷屏）。
    private var didLogFallbackPost = false

    private func post(v: (y: Double, x: Double)) {
        guard let base = baseEvent, let event = base.copy() else { return }
        MouseScrollEngine.markSynthetic(event)
        event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1.0)
        let iy = Int64(v.y.rounded())
        let ix = Int64(v.x.rounded())
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: iy)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: ix)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: v.y)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: v.x)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: v.y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: v.x)
        if targetPID > 0 {
            // 直投目标进程（不重入 tap 链，动量不跟随光标）
            event.postToPid(targetPID)
        } else {
            // 兜底：目标 PID 无效（HID 层 tap 等极端情况）时放回事件流由系统路由，
            // 合成标记（eventSourceUserData）保证不重入自身 tap。
            if !didLogFallbackPost {
                didLogFallbackPost = true
                Log.warning("[mouse][engine] 目标 PID 无效，回退 CGEventPost 投递（平滑仍可用）")
            }
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - CVDisplayLink 生命周期（调用方须持有 lock）

    private func ensureLinkLocked() {
        if displayLink == nil {
            var link: CVDisplayLink?
            if CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let l = link {
                CVDisplayLinkSetOutputCallback(l, { (_, _, _, _, _, ctx) -> CVReturn in
                    guard let ctx else { return kCVReturnSuccess }
                    let engine = Unmanaged<MouseScrollEngine>.fromOpaque(ctx).takeUnretainedValue()
                    engine.processing()
                    return kCVReturnSuccess
                }, Unmanaged.passUnretained(self).toOpaque())
                displayLink = l
            } else {
                Log.error("[mouse][engine] CVDisplayLink 创建失败，平滑滚动不可用")
                return
            }
        }
        if let l = displayLink, !linkRunning {
            if CVDisplayLinkStart(l) == kCVReturnSuccess {
                linkRunning = true
            } else {
                Log.error("[mouse][engine] CVDisplayLink 启动失败")
            }
        }
    }

    private func stopLink() {
        if let l = displayLink, linkRunning {
            CVDisplayLinkStop(l)
            linkRunning = false
        }
    }

    // MARK: - 外部控制

    func reset() {
        lock.lock()
        stopLink()
        current = (0, 0)
        delta = (0, 0)
        buffer = (0, 0)
        curveY = [0, 0]
        curveX = [0, 0]
        manualInputEnded = true
        momentumActive = false
        momentumEndScheduledTime = nil
        lastManualEventTime = 0
        baseEvent = nil
        lock.unlock()
    }
}
