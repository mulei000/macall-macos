import AppKit
import SwiftUI

extension Notification.Name {
    static let showSettings = Notification.Name("com.macall.app.showSettings")
    static let quitRequest = Notification.Name("com.macall.app.quitRequest")
    /// 全局快捷键命中后、覆盖层浮窗（`NSApp.activate`）可能触发 `applicationShouldHandleReopen`
    /// 误把设置页打开。命中时广播此通知，让 AppDelegate 在随后极短时间内忽略该 reopen。
    static let hotkeyActivation = Notification.Name("com.macall.app.hotkeyActivation")
    /// 运行时切换某功能总开关（FeatureRegistry.setEnabled）后广播。
    /// userInfo: ["id": String, "enabled": Bool]
    static let featureEnabledChanged = Notification.Name("com.macall.featureEnabledChanged")
    /// 系统音频设备列表发生变化（插入/拔出/蓝牙连接等）。
    static let audioDevicesChanged = Notification.Name("com.macall.audioDevicesChanged")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var registry: FeatureRegistry!
    private var monitor: MonitorFeature!
    private var settingsModel: SettingsModel!
    private var statusBarManager: StatusBarManager!
    private var volumeStatusBarManager: VolumeStatusBarManager!
    private var toolboxFeature: ToolboxFeature!
    private var keyboardCleanFeature: KeyboardCleanFeature!
    private var settingsWindowController: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 崩溃记录器已在 main.swift 进入 NSApplication 之前安装，此处不再重复。

        // 单实例保护：若已有实例在跑，让旧实例退出，当前新编译的二进制接管。
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppVersion.bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(.quitRequest, object: nil)
            Thread.sleep(forTimeInterval: 0.4)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: .showSettings, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .quitRequest, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        // 快捷键命中后短窗口内忽略由 `NSApp.activate` 引发的「重新打开」——否则浮层（放大镜等）
        // 激活 App 时会被误判为「用户点击 Dock」，把设置页也弹出来。真实 Dock 点击不在此窗口内。
        NotificationCenter.default.addObserver(
            forName: .hotkeyActivation, object: nil, queue: .main
        ) { [weak self] _ in
            self?.suppressReopenUntil = Date().addingTimeInterval(0.6)
        }

        // 构建功能容器。保留 MonitorFeature 实例以驱动菜单栏与仪表盘。
        let config = Configuration.load()
        monitor = MonitorFeature()
        registry = FeatureRegistry(config: config)
        let toolboxFeature = ToolboxFeature()
        let keyboardCleanFeature = KeyboardCleanFeature()
        let features: [Feature] = [
            monitor,
            PreviewFeature(),
            WindowSnapFeature(),
            HideWindowsFeature(),
            DisplayMoveFeature(),
            EdgeSnapFeature(),
            DockToggleFeature(),
            AppSwitcherFeature(),
            ClipboardHistoryFeature(),
            WindowLayoutFeature(),
            PowerActionsFeature(),
            SnippetsFeature(),
            QRFeature(),
            ColorPickerFeature(),
            VolumeFeature(),
            OutputSwitcherFeature(),
            InputSwitcherFeature(),
            MicControlFeature(),
            HotkeyCheatSheetFeature(),
            AlwaysOnTopFeature(),
            ClipboardOCRFeature(),
            MagnifierFeature(),
            DevicePriorityFeature(),
            DDCFeature(),
            TouchpadControlFeature(),
            toolboxFeature,
            keyboardCleanFeature,
        ]
        for f in features { registry.register(f) }
        registry.installAll()

        // 工具箱面板「工具箱设置」按钮跳到设置页的「工具箱」标签。
        self.toolboxFeature = toolboxFeature
        self.keyboardCleanFeature = keyboardCleanFeature
        toolboxFeature.onOpenSettings = { [weak self] in
            MainActor.assumeIsolated {
                self?.showToolsSettings()
            }
        }

        settingsModel = SettingsModel(config: config, registry: registry)

        // 状态栏 + 弹窗：照搬 macometer 的 StatusBarManager（内部已含 NSHostingView
        // 自适应宽度、弹窗自适应高度、激活后定位等做法），仅做框架接入。
        let menuVM = MenuViewModel(monitor: monitor.monitor)
        settingsWindowController = SettingsWindowController(model: settingsModel)
        statusBarManager = StatusBarManager(
            viewModel: menuVM,
            settingsWindowController: settingsWindowController,
            isMonitorEnabled: { [weak registry] in registry?.isEnabled("monitor") ?? true })
        volumeStatusBarManager = VolumeStatusBarManager(settingsWindowController: settingsWindowController, settingsModel: settingsModel)

        // Dock 图标：默认显示，点图标即可打开设置（见 applicationShouldHandleReopen）。
        installMainMenu()
        applyActivationPolicy()
        observeDockIconPreference()

        // 设置窗口被用户用红绿灯关掉时，同步 Dock 开关标记，保证下次点 Dock 能重新打开
        // （否则 dockWindowOpen 仍是 true，第一次点击会误判为「隐藏」而不打开）。
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let w = note.object as? NSWindow, w === self.settingsWindowController?.window {
                    self.dockWindowOpen = false
                }
            }
        }

        Log.startup("macall 启动 — 版本 \(AppVersion.display) (build \(AppVersion.build))")
        Log.info("[permission] 辅助功能=\(Permissions.isAccessibilityWorking()) 输入监控=\(Permissions.inputMonitoringGranted) 屏幕录制=\(Permissions.isScreenRecordingTrusted())")

        // 启动后延迟检查上次运行是否留下崩溃日志，若有则提示用户反馈。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let crashes = CrashReporter.shared.checkPreviousCrashes()
            guard !crashes.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = IadenteL10n.t("检测到 \(crashes.count) 条崩溃记录", "\(crashes.count) crash log(s) detected")
            alert.informativeText = IadenteL10n.t(
                """
                macall 上次运行发生了崩溃。两份日志都已就绪：

                ① 应用日志（含出错指令 imageOffset）
                \(CrashReporter.shared.crashDir.path)

                ② 系统崩溃报告（已符号化，定位最准）
                \(CrashReporter.shared.systemReportsDir.path)/macall-*.ips

                反馈时优先提供 ②。
                """,
                """
                macall crashed last run. Both logs are ready:

                ① App log (includes the crashing instruction imageOffset)
                \(CrashReporter.shared.crashDir.path)

                ② System crash report (symbolicated, most accurate)
                \(CrashReporter.shared.systemReportsDir.path)/macall-*.ips

                Prefer providing ② when reporting.
                """
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: IadenteL10n.t("打开系统报告", "Open System Reports"))
            alert.addButton(withTitle: IadenteL10n.t("打开应用日志", "Open App Logs"))
            alert.addButton(withTitle: IadenteL10n.t("忽略", "Ignore"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                CrashReporter.shared.revealLatestSystemReport()
            case .alertSecondButtonReturn:
                CrashReporter.shared.openCrashesFolder()
            default:
                break
            }
        }

        maybeShowWelcome()
        checkCriticalPermissions()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - Dock 图标
    //
    // Info.plist 的 `LSUIElement=true` 只决定**启动瞬间**的形态（避免冷启动时 Dock 图标
    // 一闪而过），真正生效的是运行时的 activationPolicy。这里把它做成可切换：
    //   开 → `.regular`：Dock 里有图标，点一下就打开设置（applicationShouldHandleReopen）。
    //   关 → `.accessory`：回到纯菜单栏常驻。
    //
    // 两个坑：
    //   1. 切到 `.regular` 后要 activate 一次，否则新出现的 Dock 图标偶尔不响应点击
    //      —— AppKit 需要一次激活来完成 UI 元素注册。
    //   2. 切回 `.accessory` 时若本 App 正在最前台，菜单栏会残留我们的菜单，
    //      所以要主动把前台让出去。

    private func applyActivationPolicy() {
        let wantDock = Defaults[.showDockIcon]
        let target: NSApplication.ActivationPolicy = wantDock ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if wantDock {
            NSApp.activate(ignoringOtherApps: false)
        } else {
            NSApp.deactivate()
        }
        Log.info("[dock] 图标\(wantDock ? "已显示" : "已隐藏")（activationPolicy=\(wantDock ? "regular" : "accessory")）")
    }

    private func observeDockIconPreference() {
        Task { [weak self] in
            for await _ in Defaults.updates(.showDockIcon, initial: false) {
                self?.applyActivationPolicy()
            }
        }
    }

    /// `.regular` 模式下 App 会占据菜单栏，`NSApp.mainMenu` 为 nil 时那里是一片空白，看着像坏了。
    /// 顺带补上标准「编辑」菜单——没有它，设置窗口里的输入框连 ⌘C / ⌘V 都用不了。
    private func installMainMenu() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: IadenteL10n.t("关于 macall", "About macall"),
            action: Selector(("orderFrontStandardAboutPanel:")), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: IadenteL10n.t("设置…", "Settings…"),
            action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: IadenteL10n.t("隐藏 macall", "Hide macall"),
            action: Selector(("hide:")), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: IadenteL10n.t("退出 macall", "Quit macall"),
            action: Selector(("terminate:")), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: IadenteL10n.t("编辑", "Edit"))
        let editEntries: [(String, String, String, String)] = [
            ("撤销", "Undo", "undo:", "z"),
            ("重做", "Redo", "redo:", "Z"),
            ("", "", "-", ""),
            ("剪切", "Cut", "cut:", "x"),
            ("拷贝", "Copy", "copy:", "c"),
            ("粘贴", "Paste", "paste:", "v"),
            ("全选", "Select All", "selectAll:", "a"),
        ]
        for (zh, en, sel, key) in editEntries {
            if sel == "-" {
                editMenu.addItem(.separator())
            } else {
                editMenu.addItem(
                    withTitle: IadenteL10n.t(zh, en), action: Selector((sel)), keyEquivalent: key)
            }
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 设置窗口（由 macometer 风格的 StatusBarManager 与欢迎流程共用）

    @objc func showSettings() {
        settingsWindowController?.showSettings(tab: .general)
    }

    /// 工具箱面板的「工具箱设置」按钮：跳到设置页的「工具箱」标签。
    @objc func showToolsSettings() {
        settingsWindowController?.showSettings(tab: .tools)
    }

    /// 冷启动后把设置窗口带到最前台，确保用户「看得到」应用已打开
    /// （菜单栏 app 默认安静驻留、不弹窗，容易被误以为「没打开」）。
    private func maybeShowWelcome() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showSettings()
        }
    }

    // MARK: - 关键权限自检

    /// 启动后主动检查「辅助功能」。这一项一旦缺失，全局快捷键（CGEventTap 需要辅助功能
    /// 才能以 `.defaultTap` 方式消费按键）与全部窗口操作（AX API）会**同时静默失效**——
    /// 外在表现就是「所有功能都用不了」，而界面上没有任何提示，用户只会以为程序坏了。
    /// 因此这里必须弹窗告知并直达系统设置，而不是只写一行日志。
    private func checkCriticalPermissions() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            // 已经在跑欢迎流程（首次启动会弹设置窗）时往后让一让，避免两个窗打架。
            if Permissions.isAccessibilityWorking() { return }
            // 用自定义浮层（含「拖入 macall 自动授权」拖拽区）取代 NSAlert；
            // 重启逻辑已迁至 PermissionGuideController.relaunch()。
            PermissionGuideController.shared.show()
        }
    }

    /// 应用获得焦点时（权限通常已授予）重建全局监听。
    func applicationDidBecomeActive(_ notification: Notification) {
        registry?.ensureAllTaps()
    }

    @objc private func didWake() {
        registry?.reenableAll()
    }

    /// Dock 图标点击状态机。
    ///
    /// 用「我们自己的开关标记」代替 `window.isVisible` 来判断该开还是该关——
    /// 因为 macOS 在点击 Dock 图标时**会先把隐藏的 App 自动解隐藏**（设置窗口
    /// 闪现一下），紧接着才回调本方法。此时若只看 `isVisible`，永远读到 true，
    /// 于是每次点击都走进「隐藏」分支再 `NSApp.hide` 把窗口藏回去，表现为
    /// 「闪一下就消失」的死循环。所以这里维护 `dockWindowOpen` 作为唯一事实来源。
    private var dockWindowOpen = false
    /// 双触发时间防御：macOS 对同一物理点击可能连续回调本方法两次（间隔数毫秒），
    /// 第一次已经开了/关了，第二次直接忽略，避免刚打开又被立刻关掉。
    private var lastDockActionAt: Date?
    /// 快捷键命中后、覆盖层 `NSApp.activate` 会触发「重新打开」；此时间窗内忽略，
    /// 避免把设置页误弹出来。真实 Dock 点击不在此窗口内。
    private var suppressReopenUntil: Date = .distantPast

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // 覆盖层（放大镜/二维码/取色/片段…）激活 App 时触发的 reopen：直接忽略。
        if Date() < suppressReopenUntil {
            Log.info("[dock] 覆盖层激活引发的 reopen，忽略（不弹设置页）")
            return true
        }
        let now = Date()
        // 双触发防御：极短时间内已处理过一次本点击 → 忽略后续回调。
        if let t = lastDockActionAt, now.timeIntervalSince(t) < 0.6 {
            Log.info("[dock] 点击 Dock 图标：双触发去抖，忽略")
            return true
        }
        lastDockActionAt = now

        if dockWindowOpen {
            // 当前是「已打开」→ 收起设置窗口。
            // 用 `orderOut` 隐藏窗口而不是 `miniaturize`：最小化会把窗口收进 Dock，
            // 而恢复时 `makeKeyAndOrderFront` 对最小化窗口无效，导致下次点图标「打不开」；
            // orderOut 只是临时隐藏，窗口对象仍在，下次 showSettings 能可靠地重新置前。
            statusBarManager?.closePanel()
            settingsWindowController?.window?.orderOut(nil)
            dockWindowOpen = false
            Log.info("[dock] 点击 Dock 图标：收起设置窗口")
        } else {
            // 兜底：若窗口曾被最小化（旧状态残留），先恢复再置前。
            if let win = settingsWindowController?.window, win.isMiniaturized {
                win.deminiaturize(nil)
            }
            showSettings()
            dockWindowOpen = true
            Log.info("[dock] 点击 Dock 图标：打开设置窗口")
        }
        return true
    }

    // MARK: - URL Scheme（macall:// 控制音量 / 设备）

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        handleURL(url)
    }

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "macall" else { return }
        let abs = url.absoluteString
        // 去掉 "macall:" 前缀（兼容 macall:// 与 macall: 两种写法）
        let withoutScheme: String
        if let r = abs.range(of: "macall:") { withoutScheme = String(abs[r.upperBound...]) }
        else { withoutScheme = abs }
        let parts = withoutScheme.split(separator: "?", maxSplits: 1)
        let pathPart = parts.first.map(String.init) ?? ""
        let queryString = parts.count > 1 ? String(parts[1]) : ""
        let pathComps = pathPart.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !pathComps.isEmpty else { return }
        let action = pathComps[0].lowercased()
        let sub = pathComps.count > 1 ? pathComps[1].lowercased() : ""

        // 解析查询参数
        var params: [String: String] = [:]
        for item in queryString.split(separator: "&") {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        let param = { (k: String) -> String? in params[k] }

        guard let model = settingsModel else { return }

        switch (action, sub) {
        case ("volume", "set"):
            if let app = param("app"), !app.isEmpty {
                if let v = param("value").flatMap(Double.init) {
                    model.config.perAppVolume[app] = min(max(v, 0), 2)
                }
            } else if let v = param("value").flatMap(Double.init) {
                VolumeCore.setVolume(Float(min(max(v, 0), 1)))
            }
            model.save()
        case ("volume", "mute"):
            if let app = param("app"), !app.isEmpty,
               let v = param("value").flatMap(Double.init) {
                model.config.perAppMuted[app] = (v != 0)
                model.save()
            }
        case ("device", "set"):
            if let uid = param("uid") {
                model.config.outputDeviceUIDs = (uid.lowercased() == "default") ? [] : [uid]
                model.save()
            }
        default:
            break
        }
    }

}
