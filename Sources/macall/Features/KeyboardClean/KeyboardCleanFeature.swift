import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import Combine

// MARK: - 键盘清洁（锁定整个键盘方便擦灰）
//
// 思路参考 GitHub 上的开源方案：在 HID 层（`CGEventTapOptions` 默认 tap，放置于
// `.cghidEventTap`）拦截键盘事件。清洁开启时把 keyDown / keyUp / flagsChanged /
// sysKeyDown / sysKeyUp 全部 `return nil` 吞掉，键盘（含媒体键）彻底失效，但
// **鼠标完全不动** —— 这样既能放心擦键盘，又留了「用鼠标点按钮」这条解锁通道。
//
// 关键安全设计：
//   · 永不锁鼠标，解锁只能靠鼠标点击或倒计时自动结束；
//   · 进入清洁时建一个临时状态栏图标（用完即删），方便随时查看/结束；
//   · `applicationWillTerminate` 与 `atexit` 双保险强制移除 tap，
//     即使 app 崩溃/被杀也不会让键盘永久死锁（tap 是进程内资源，进程没了系统也会回收）。
//
// 与工具箱图标完全独立：工具箱图标常驻，清洁图标只在清洁期间出现。

final class KeyboardCleanFeature: Feature {
    let id = "keyboardclean"
    let title = IadenteL10n.t("清洁模式", "Clean Mode")
    let category = FeatureCategory.other
    var enabledByDefault: Bool = true

    private var context: AppContext?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var isActive = false
    private var remaining: Int = 0

    private var statusItem: NSStatusItem?
    private var panel: KeyboardCleanPanel?
    private var hosting: NSHostingController<KeyboardCleanView>?
    private let model = KeyboardCleanModel()

    // 清洁模式：进入后自动熄屏相关状态。
    private var caffeinate: Process?                    // 阻止系统整体睡眠的子进程
    private var pendingSleep: DispatchWorkItem?         // 延迟熄屏任务（期间结束则取消）

    private static var shared: KeyboardCleanFeature?

    // MARK: - Feature

    func install(context: AppContext) {
        self.context = context
        Self.shared = self
        // 崩溃兜底：进程退出时（含 crash）强制回收 tap，避免键盘死锁。
        atexit { KeyboardCleanFeature.shared?.teardownTap() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.forceStop()
        }
        Log.info("[keyboardclean] 已安装：键盘清洁功能就绪（按需启动拦截 tap）")
    }

    func uninstall() { forceStop() }
    func reload(config: Configuration) {}
    func ensureTap() {}
    func reenable() {}

    func handle(action: String) {
        if action == "toggle" { toggle() }
    }

    // MARK: - 启停

    func toggle() {
        if isActive { stop() } else { startCleaning() }
    }

    private func startCleaning() {
        guard !isActive else { return }
        guard ensurePermission() else { return }

        installTap()
        guard tap != nil else {
            // tap 创建失败（权限不足等），已在 installTap 内记录，给个提示。
            presentTapFailedAlert()
            return
        }

        isActive = true
        remaining = max(5, Defaults[.cleanCountdownSeconds])
        model.remaining = remaining
        startTimer()
        showStatusItem()
        showPanel()
        scheduleDisplaySleep()
        Log.info("[keyboardclean] 清洁模式开启，键盘已锁定（剩余 \(remaining)s）")
    }

    private func stop() {
        guard isActive else { return }
        forceStop()
        Log.info("[keyboardclean] 清洁模式结束，键盘已恢复")
    }

    /// 完整收尾（移除 tap + 停计时 + 删图标 + 关面板 + 解除熄屏相关状态）。
    func forceStop() {
        guard isActive else { return }
        isActive = false
        cancelPendingSleep()
        wakeDisplays()
        teardownTap()
        stopTimer()
        hideStatusItem()
        hidePanel()
    }

    // MARK: - 自动熄屏（清洁模式进入时黑屏看灰尘）

    /// 进入清洁模式后，先亮屏显示确认面板，延迟片刻再熄屏；
    /// 若期间已结束，pendingSleep 被取消，不会误熄屏。仅在设置开启时生效。
    private func scheduleDisplaySleep() {
        guard Defaults[.cleanAutoDisplaySleep] else { return }
        startCaffeinate()   // 阻止系统整体睡眠，但允许显示器睡眠
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.sleepDisplaysNow()
        }
        pendingSleep = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func cancelPendingSleep() {
        pendingSleep?.cancel()
        pendingSleep = nil
        stopCaffeinate()
    }

    /// 用 pmset 强制显示器睡眠（背光关闭），与 PowerActionsFeature 同一可靠路径。
    private func sleepDisplaysNow() {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.launchPath = "/usr/bin/pmset"
            process.arguments = ["displaysleepnow"]
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            try? process.run()
        }
    }

    /// 退出或倒计时归零时唤醒屏幕：轻微移动光标即可点亮显示器，便于看到面板已结束。
    private func wakeDisplays() {
        let loc = NSEvent.mouseLocation
        CGWarpMouseCursorPosition(CGPoint(x: loc.x + 1, y: loc.y + 1))
    }

    /// 清洁期间用 `caffeinate -i` 阻止系统整体睡眠（否则 mac 睡死 + 键盘被锁会很难唤醒），
    /// 但不阻止显示器睡眠。退出时 terminate。
    private func startCaffeinate() {
        guard caffeinate == nil else { return }
        let p = Process()
        p.launchPath = "/usr/bin/caffeinate"
        p.arguments = ["-i"]
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        try? p.run()
        caffeinate = p
    }

    private func stopCaffeinate() {
        guard let p = caffeinate else { return }
        p.terminate()
        caffeinate = nil
    }

    // MARK: - 权限

    private func ensurePermission() -> Bool {
        let ax = Permissions.isAccessibilityWorking()
        let input = Permissions.inputMonitoringGranted
        guard ax, input else {
            DispatchQueue.main.async { [weak self] in
                self?.presentPermissionAlert(ax: ax, input: input)
            }
            return false
        }
        return true
    }

    private func presentPermissionAlert(ax: Bool, input: Bool) {
        let alert = NSAlert()
        alert.messageText = IadenteL10n.t(
            "清洁模式需要辅助功能权限", "Clean Mode needs Accessibility")
        var info = IadenteL10n.t(
            "要锁定键盘，macall 需要「辅助功能」权限。",
            "To lock the keyboard, macall needs Accessibility access.")
        if !input {
            info += "\n" + IadenteL10n.t(
                "建议同时开启「输入监控」。",
                "Input Monitoring is also recommended.")
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: IadenteL10n.t("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: IadenteL10n.t("取消", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    private func presentTapFailedAlert() {
        let alert = NSAlert()
        alert.messageText = IadenteL10n.t("无法启动清洁模式", "Cannot start Clean Mode")
        alert.informativeText = IadenteL10n.t(
            "系统未能创建键盘拦截（可能是辅助功能 / 输入监控权限不足，或被其它工具占用）。请在系统设置中确认 macall 已获授权后重试。",
            "The system could not create the keyboard tap (permission missing or in use). Re-enable macall in System Settings and try again.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: IadenteL10n.t("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: IadenteL10n.t("好", "OK"))
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    // MARK: - 事件拦截 tap

    private func installTap() {
        guard tap == nil else { return }
        // 媒体键（亮度/音量等）在 macOS 上同样以 keyDown/keyUp 投递，
        // 所以只拦 keyDown/keyUp/flagsChanged 即可锁住「整个键盘」（含媒体键）。
        // 拆成多条子表达式，避免整条 CGEventMask 初始化触发「无法在合理时间内类型检查」。
        var rawMask: UInt64 = 0
        rawMask |= UInt64(1) << CGEventType.keyDown.rawValue
        rawMask |= UInt64(1) << CGEventType.keyUp.rawValue
        rawMask |= UInt64(1) << CGEventType.flagsChanged.rawValue
        let mask: CGEventMask = rawMask
        // C 函数指针回调不能捕获上下文（[weak self] 会触发编译错误）。
        // 通过 userInfo 传 self 的裸指针，回调内用 Unmanaged 取回，从而重新启用超时禁用的 tap。
        // 与项目里 HotkeyManager / DockToggleFeature 等事件 tap 的写法保持一致。
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            // tap 因超时被系统禁用时，立刻重新启用（回调必须快，这里只做恢复）。
            if type == .tapDisabledByTimeout {
                if let ptr = userInfo {
                    let f = Unmanaged<KeyboardCleanFeature>.fromOpaque(ptr).takeUnretainedValue()
                    if let t = f.tap { CGEvent.tapEnable(tap: t, enable: true) }
                }
                return nil
            }
            switch type {
            case .keyDown, .keyUp, .flagsChanged:
                // 吞掉所有键盘事件（含媒体键），但鼠标事件不在掩码内，照常放行。
                return nil
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
            Log.error("[keyboardclean] 无法创建键盘拦截 tap（权限不足或被占用）")
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("[keyboardclean] 键盘拦截 tap 已创建并启用")
    }

    /// 仅移除 tap（崩溃兜底用，不碰 UI）。
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

    // MARK: - 倒计时

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remaining -= 1
            self.model.remaining = max(0, self.remaining)
            if self.remaining <= 0 {
                self.stop()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 临时状态栏图标（清洁期间出现，用完消失）

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        if let img = NSImage(systemSymbolName: "keyboard.badge.ellipsis.fill",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            button.image = img
        }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = IadenteL10n.t(
            "清洁模式进行中：点击查看或结束", "Cleaning mode: click to view or end")
        statusItem = item
    }

    private func hideStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - 清洁中面板（倒计时 + 鼠标解锁按钮）

    private func configurePanel() -> KeyboardCleanPanel {
        if let panel, let _ = hosting {
            return panel
        }
        let controller = NSHostingController(rootView: KeyboardCleanView(
            model: model, onStop: { [weak self] in self?.stop() }))
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 14
        controller.view.layer?.masksToBounds = true

        let p = KeyboardCleanPanel(contentViewController: controller)
        p.styleMask = [.borderless, .nonactivatingPanel]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.appearance = Defaults[.appearanceMode].nsAppearance

        panel = p
        hosting = controller
        return p
    }

    private func showPanel() {
        let p = configurePanel()
        let width: CGFloat = 280
        let height: CGFloat = 360
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2)
        p.setFrame(NSRect(x: origin.x.rounded(), y: origin.y.rounded(),
                          width: width, height: height), display: false)
        p.orderFrontRegardless()
        p.makeKey()
        Log.info("[keyboardclean] 显示清洁面板")
    }

    private func hidePanel() {
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
    }
}

// MARK: - 面板

private final class KeyboardCleanPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 清洁状态数据，供 SwiftUI 面板观察倒计时。
final class KeyboardCleanModel: ObservableObject {
    @Published var remaining: Int = 0
}

private struct KeyboardCleanView: View {
    @ObservedObject var model: KeyboardCleanModel
    let onStop: () -> Void

    var body: some View {
        ZStack {
            IadenteWindowBackdrop()
            VStack(spacing: 14) {
                Image(systemName: "keyboard.badge.ellipsis.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(IadenteTheme.aboutColors.first ?? .accentColor)

                Text(IadenteL10n.t("清洁模式已开启", "Clean Mode On"))
                    .font(.system(size: 16, weight: .semibold))

                Text(IadenteL10n.t(
                    "可以放心清洁了。屏幕已熄屏，移动鼠标可唤醒；用鼠标点「立即结束」，或等倒计时结束自动解锁。",
                    "Clean away. The display is off — move the mouse to wake it. Click End now below, or wait for the countdown."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)

                Text("\(model.remaining)")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(IadenteTheme.aboutColors.first ?? .accentColor)
                    .contentTransition(.numericText())

                Button(action: onStop) {
                    Label(IadenteL10n.t("立即结束", "End now"),
                          systemImage: "lock.open.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: 200)
                        .padding(.vertical, 8)
                }
                .buttonStyle(IadenteActionButtonStyle(colors: IadenteTheme.aboutColors))

                Text(IadenteL10n.t(
                    "提示：清洁期间键盘（含媒体键）已锁定、屏幕已熄屏；移动鼠标唤醒后点「立即结束」即可结束。",
                    "Tip: during cleaning the keyboard (incl. media keys) is locked and the display is off; move the mouse to wake it, then click End now."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }
            .padding(22)
        }
    }
}
