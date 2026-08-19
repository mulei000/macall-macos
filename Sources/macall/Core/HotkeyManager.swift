import ApplicationServices
import CoreGraphics
import Foundation

/// Owns a single session-level keyboard event tap. Features register their
/// hotkeys here; when a registered combo fires, the matching feature's
/// `handle(action:)` is invoked. Matched keystrokes are consumed so they never
/// leak through to the foreground app.
///
/// 移植自自有项目 Macindow（MIT），沿用其验证过的写法。
final class HotkeyManager {
    private struct Binding {
        let featureId: String
        let action: String
        let configKey: String
        let defaultCombo: HotkeyCombo
    }

    private var bindings: [Binding] = []
    private var lookup: [HotkeyCombo: (featureId: String, action: String)] = [:]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    weak var registry: FeatureRegistry?

    func bind(featureId: String, action: String, configKey: String, defaultCombo: HotkeyCombo) {
        bindings.append(Binding(featureId: featureId, action: action, configKey: configKey, defaultCombo: defaultCombo))
    }

    /// Rebuild the match table from the current configuration. Newly bound
    /// combos use the default; user overrides in config take precedence.
    /// Actions whose feature is toggled off are skipped entirely.
    func rebuild(config: Configuration) {
        lookup.removeAll()
        for b in bindings {
            guard registry?.isEnabled(b.featureId) ?? true else { continue }
            // 子功能（单个快捷键）被单独关闭时不绑定，但其组合键仍保留在配置里。
            guard config.isHotkeyEnabled(b.configKey, default: true) else { continue }
            let combo = config.hotkeys[b.configKey]?.toCombo() ?? b.defaultCombo
            lookup[combo] = (b.featureId, b.action)
        }
    }

    /// Temporarily disable the global tap (used while the user is recording a
    /// new shortcut so the keystroke isn't swallowed by our own handler).
    func suspend() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    func resume() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    var isActive: Bool { tap != nil }

    /// Create the keyboard tap. Idempotent — safe to call repeatedly; it only
    /// (re)creates the tap when it does not already exist. This is what lets us
    /// recover when the first attempt at launch failed because the user had not
    /// yet granted Input Monitoring permission.
    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(UInt64(1) << UInt64(CGEventType.keyDown.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo, type == .keyDown else {
                return Unmanaged.passRetained(event)
            }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return mgr.handleKeyEvent(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Log.error("无法创建键盘监听（输入监控/辅助功能权限不足，或 tap 已在别处被占用）")
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Permissions.inputMonitoringGranted = true
        Log.info("键盘监听已启动 (taps created)")
    }

    /// Re-create the keyboard tap if it is currently missing. Returns whether the
    /// tap is active afterwards (i.e. whether shortcuts will work).
    @discardableResult
    func ensureStarted() -> Bool {
        start()
        let ok = tap != nil
        Log.info("ensureStarted -> 键盘监听: \(ok ? "已就绪" : "创建失败")")
        return ok
    }

    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func handleKeyEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Master on/off: when disabled, let every keystroke pass through.
        if !(registry?.config.enabled ?? true) {
            return Unmanaged.passRetained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = relevantFlags(event)
        let combo = HotkeyCombo(keyCode: keyCode, flags: flags)
        if let hit = lookup[combo] {
            // Ignore OS key auto-repeat so a *held* key doesn't re-fire the
            // action continuously.
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
            if autorepeat != 0 {
                return nil
            }
            Log.info("命中快捷键: keyCode=\(keyCode) flags=\(flags) -> \(hit.featureId).\(hit.action)")
            // 广播「快捷键命中」：随后覆盖层会 `NSApp.activate`，可能触发
            // applicationShouldHandleReopen 误弹设置页；AppDelegate 收到后会短窗口忽略该 reopen。
            NotificationCenter.default.post(name: .hotkeyActivation, object: nil)
            DispatchQueue.main.async { [weak self] in
                self?.registry?.dispatch(featureId: hit.featureId, action: hit.action)
            }
            return nil
        }
        // Unmatched keystroke — pass it through untouched.
        return Unmanaged.passRetained(event)
    }
}
