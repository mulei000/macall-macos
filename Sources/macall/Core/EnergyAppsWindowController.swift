import AppKit
import SwiftUI

/// 「全部耗电 App」列表窗口。照搬 macometer 的实现：用 NSHostingController 承载
/// SwiftUI 的 `EnergyAppsFullListView`，仅在窗口打开期间轮询，关闭即释放。
@MainActor
final class EnergyAppsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: EnergyAppsFullListView())
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = IadenteL10n.t("耗电应用", "Energy Apps")
        newWindow.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.appearance = Defaults[.appearanceMode].nsAppearance
        newWindow.contentView?.wantsLayer = true
        newWindow.contentView?.layer?.cornerRadius = 14
        newWindow.contentView?.layer?.masksToBounds = true
        newWindow.setContentSize(NSSize(width: 360, height: 440))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow

        Task { [weak self] in
            for await _ in Defaults.updates(.appearanceMode, initial: false) {
                self?.window?.appearance = Defaults[.appearanceMode].nsAppearance
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
        }
    }
}
