import AppKit
import SwiftUI

/// 设置窗口控制器。
/// 承载 macall 的 SettingsView；窗口使用透明材质背景，内容由 SwiftUI 的
/// IadenteWindowBackdrop 负责填充，避免旧版 SettingsView 顶层无背景导致的透明问题。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        super.init()
        startAppearanceObservation()
    }

    private func startAppearanceObservation() {
        Task { [weak self] in
            for await _ in Defaults.updates(.appearanceMode, initial: false) {
                guard let self else { return }
                self.window?.appearance = Defaults[.appearanceMode].nsAppearance
            }
        }
    }

    /// 把 macometer 仪表盘弹出的 SettingsTab 映射到 macall 的设置标签页。
    /// 弹窗模块布局已合并到「通用」，因此原 .dashboard 也映射到 .general。
    private func mapTab(_ tab: SettingsTab) -> MacallSettingsTab {
        switch tab {
        case .general:  return .general
        case .advanced: return .advanced
        case .about:    return .about
        case .audio:    return .audio
        case .tools:    return .tools
        }
    }

    func showSettings(tab: SettingsTab = .general) {
        let macallTab = mapTab(tab)

        // 复用已存在的窗口，只切换标签页并置前。
        if let existingWindow = window,
           let hosting = existingWindow.contentViewController as? NSHostingController<SettingsView> {
            hosting.rootView = SettingsView(model: model, initialTab: macallTab)
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(model: model, initialTab: macallTab)
        let hostingController = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = IadenteL10n.t("macall 设置", "macall Settings")
        newWindow.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .fullSizeContentView,
        ]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        // 背景透明：由 SwiftUI 的 IadenteWindowBackdrop 完整填充，
        // 这样设置页可以呈现 macometer 风格的毛玻璃/渐变背景。
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.appearance = Defaults[.appearanceMode].nsAppearance
        newWindow.contentView?.wantsLayer = true
        newWindow.contentView?.layer?.cornerRadius = 14
        newWindow.contentView?.layer?.masksToBounds = true
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self

        let windowSize = NSSize(width: 960, height: 660)
        newWindow.setContentSize(windowSize)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let originX = visible.origin.x + (visible.width - windowSize.width) / 2
            let originY = visible.origin.y + (visible.height - windowSize.height) / 2
            newWindow.setFrame(
                NSRect(
                    x: originX,
                    y: originY,
                    width: windowSize.width,
                    height: windowSize.height
                ),
                display: false
            )
        } else {
            newWindow.center()
        }

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
        }
    }
}
