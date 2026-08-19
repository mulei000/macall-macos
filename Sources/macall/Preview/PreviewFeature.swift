import Cocoa
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Multi-window Dock hover preview layout constants
private let previewCardInnerW: CGFloat = 200
private let previewCardInnerH: CGFloat = 130
private let previewCardTitleH: CGFloat = 24
private let previewCardPad: CGFloat = 8
private let previewCardW: CGFloat = previewCardInnerW + previewCardPad * 2   // 216
private let previewCardH: CGFloat = previewCardInnerH + previewCardTitleH + previewCardPad * 2  // 170
private let previewGap: CGFloat = 8
private let previewSidePad: CGFloat = 10
private let previewHeaderH: CGFloat = 26

// MARK: - Vorssaint-backed capture (shared structural validation)
//
// Delegates to `VSCaptureBridge` — the single capture path shared with the
// ⌘⌥Tab switcher — so the Dock preview gets the same window-server capture and
// Stage Manager / clipped-edge rejection, and a rejected capture falls back to
// the app icon (nil).
private func vsThumbnail(_ wid: CGWindowID,
                         windowSize: CGSize, isMinimized: Bool,
                         maxDim: CGFloat = 720) -> NSImage? {
    VSCaptureBridge.thumbnail(windowID: wid,
                              windowSize: windowSize,
                              isMinimized: isMinimized,
                              maxDim: maxDim)
}

/// One capturable window of an app, for the multi-window Dock hover row.
private struct WindowThumb {
    let cgWindowID: CGWindowID
    let title: String
    let image: NSImage?
    /// Fallback icon shown when screenshot is unavailable / unreliable.
    let appIcon: NSImage?
    let state: WindowState
    let appName: String
    /// The AX window element — always present when enumerated via AX.windows.
    /// Used for precise open/close/min/max actions (more reliable than CGID lookup).
    let axWindow: AXUIElement?
}

/// Windows-style Dock hover preview: when the mouse lingers over an open app's
/// Dock icon, a floating panel shows a live thumbnail of that app's front
/// window. Pure public APIs — a global `mouseMoved` tap locates the hovered
/// Dock icon, then `CGWindowListCreateImage` captures the thumbnail.
final class PreviewFeature: Feature {
    let id = "preview"
    var title: String { IadenteL10n.t("窗口预览", "Window Preview") }
    var category: FeatureCategory { .window }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var panel: NSPanel?
    /// Panel's on-screen CG rect (set when positioning) so that when the pointer
    /// moves onto the preview itself we don't treat it as "left the Dock" and hide.
    private var panelCGRect: CGRect?
    private var context: AppContext?
    private var enabled = true

    private var lastPID: pid_t = 0
    private var lastMoveCheck = Date.distantPast
    private var cachedIcons: [(rect: CGRect, bundleID: String)] = []
    private var screenRecRequested = false

    func install(context: AppContext) {
        self.context = context
        self.enabled = context.config.previewEnabled
        installTap()
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(UInt64(1) << UInt64(CGEventType.mouseMoved.rawValue))
        let cb: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let f = Unmanaged<PreviewFeature>.fromOpaque(userInfo).takeUnretainedValue()
            // macOS silently disables slow taps — re-enable ourselves (self-heal).
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = f.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passRetained(event)
            }
            guard type == .mouseMoved else { return Unmanaged.passRetained(event) }
            f.handleMove(event)
            return Unmanaged.passRetained(event) // never consume mouse moves
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: cb,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Log.error("窗口预览：无法创建鼠标监听（请确认辅助功能已授权，并在设置中点击「重新加载监听」）")
            return
        }
        self.tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        Log.info("窗口预览(悬停)已启动")
    }

    func ensureTap() { installTap() }

    private func handleMove(_ event: CGEvent) {
        guard enabled, context?.config.enabled ?? true else { hide(); return }
        // Throttle: the window-list query is expensive; doing it on EVERY
        // mouse-moved event is what got the tap disabled by timeout.
        let now = Date()
        guard now.timeIntervalSince(lastMoveCheck) > 0.08 else { return }
        lastMoveCheck = now
        let cg = event.location
        guard let dockRect = DockDetector.dockRect(), dockRect.contains(cg) else {
            // The pointer is over our own preview panel (above the Dock) — keep it
            // so the traffic-light buttons (and the click-to-open gesture) stay
            // live instead of vanishing. We also keep the panel while the cursor
            // is in the thin dead gap BETWEEN the Dock bar and the panel (the
            // panel sits ~4px above the Dock): moving the mouse from an icon up to
            // the panel crosses that gap, and without this tolerance a mouseMoved
            // sampled there would hide() the panel before the click could land —
            // which is exactly why single-window preview clicks appeared dead.
            if let r = panelCGRect, r.insetBy(dx: 0, dy: -16).contains(cg) { return }
            hide(); return
        }

        // DockDetector.dockAppItems() is internally cached (0.8 s TTL).
        cachedIcons = DockDetector.dockAppItems()
        guard let hit = cachedIcons.first(where: { $0.rect.contains(cg) }),
              let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == hit.bundleID }) else {
            hide(); return
        }
        if app.processIdentifier == lastPID, panel != nil { return } // same icon, keep panel
        lastPID = app.processIdentifier
        // Anchor to the ICON rect (not the cursor): the card then sits still
        // while the pointer wanders inside the icon, and lines up with the Dock.
        showPreview(for: app, iconRect: hit.rect, dockRect: dockRect)
    }

    private func showPreview(for app: NSRunningApplication, iconRect: CGRect, dockRect: CGRect) {
        // Icon-only apps (system UIs, Finder, …) and any app with NO real window
        // (background / UI-less Dock apps, menubar agents — the "Launchpad-like"
        // case): their window frame is either unreliable/blank or simply absent,
        // so never attempt a capture — just show the app icon. This also avoids
        // leaving a dead panel up for windowless apps.
        if AppClassifier.isIconOnly(app) || !AppClassifier.hasRealWindow(app) {
            showIconPreview(for: app, iconRect: iconRect, dockRect: dockRect)
            return
        }

        // Multi-window app → show every window as a clickable thumbnail grid.
        // (The icon-click "reverse all" behaviour lives in DockToggleFeature and
        // is intentionally left untouched — there's no way to pick one there.)
        let thumbs = Self.windowThumbs(for: app)
        if thumbs.count > 1 {
            showMultiPreview(for: app, thumbs: thumbs, iconRect: iconRect, dockRect: dockRect,
                             isHorizontal: dockRect.width > dockRect.height)
            return
        }

        // ---- single-window / cached path (unchanged behaviour) ----
        // NOTE: Do NOT hard-gate previews on isScreenRecordingTrusted(). Its
        // underlying CGPreflightScreenCaptureAccess() returns FALSE for an extended
        // window right after launch even when Screen Recording is already granted
        // (TCC state settles lazily — it only flips to true after the app becomes
        // active / the user switches apps a few times). Gating here would suppress
        // every Dock-hover preview at startup, which is exactly the bug reported.
        // So we just ATTEMPT the capture; a genuine permission problem surfaces as
        // "no frame" below, and we only log/prompt as a *non-blocking* hint then.
        guard let info = Self.thumbnailInfo(for: app) else {
            if !Permissions.isScreenRecordingTrusted(), !screenRecRequested {
                Log.error("悬停预览：缺少屏幕录制权限，无法截取窗口缩略图（系统设置→隐私与安全性→屏幕录制 勾选 macall）")
                Permissions.requestScreenRecording()
                screenRecRequested = true
            }
            hide()
            return
        }
        let appName = app.localizedName ?? "App"
        let badge: String? = info.state == .live ? nil : (info.state == .hidden ? IadenteL10n.t("已隐藏", "Hidden") : IadenteL10n.t("已缩小", "Minimized"))

        // Fixed thumbnail height; the image is shown at its FULL height (never
        // cropped — uses .scaledToFit inside this fixed-height frame) and the
        // card WIDTH follows the window's aspect ratio, so wide/tall windows all
        // display completely without forcing a taller card.
        let thumbH: CGFloat = 170
        let aspect = max(info.image.size.width, 1) / max(info.image.size.height, 1)
        let thumbW = min(max(thumbH * aspect, 140), 380)
        let pad: CGFloat = 10
        let textH: CGFloat = 40
        let panelW = thumbW + pad * 2
        let panelH = thumbH + textH + pad * 2

        let view = DockPreviewView(image: Image(nsImage: info.image),
                                   appName: appName,
                                   windowTitle: info.title,
                                   thumbW: thumbW, thumbH: thumbH, textH: textH,
                                   badge: badge,
                                   onClose: { [weak self] in self?.performClose(app) },
                                   onMin: { [weak self] in self?.performMinimize(app) },
                                   onMax: { [weak self] in self?.performMaximize(app) },
                                   onOpen: { [weak self] in self?.openWindow(info.cgWindowID, axWin: nil, app: app) })

        guard let p = ensurePanel() else { return }
        // Interactive preview: the panel MUST receive clicks (traffic lights /
        // cards). Reset the click-through flag in case the icon-only path set it.
        p.ignoresMouseEvents = false
        // Mount through FirstMouseHostingView so the first click is delivered to
        // the buttons instead of being eaten by "make this panel key".
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        p.contentView = host
        p.setContentSize(NSSize(width: panelW, height: panelH))
        positionPanel(iconRect: iconRect, dockRect: dockRect)
        p.orderFrontRegardless()
    }

    /// Icon-only apps (Finder, Launchpad, …): show the app icon instead of a
    /// window preview. The window capture for these is unreliable / blank, so the
    /// user explicitly asked for "just show the app icon" rather than a broken
    /// frame. No traffic-light controls — there is no window to act on.
    private func showIconPreview(for app: NSRunningApplication, iconRect: CGRect, dockRect: CGRect) {
        guard let icon = app.icon else { hide(); return }
        let appName = app.localizedName ?? "App"
        let iconSize: CGFloat = 96
        let textH: CGFloat = 30
        let pad: CGFloat = 14
        let panelW = iconSize + pad * 2
        let panelH = iconSize + textH + pad * 2
        let view = DockIconPreviewView(icon: Image(nsImage: icon), appName: appName,
                                       iconSize: iconSize, textH: textH)
        guard let p = ensurePanel() else { return }
        // The icon card has no interactive controls, so make it click-through:
        // otherwise this high-level (popUpMenu) panel would sit ON TOP of the
        // app's own window (e.g. a Finder window whose bottom edge rests just
        // above the Dock) and swallow every click meant for that window — which
        // is exactly the "访达点了没反应" symptom.
        p.ignoresMouseEvents = true
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        p.contentView = host
        p.setContentSize(NSSize(width: panelW, height: panelH))
        positionPanel(iconRect: iconRect, dockRect: dockRect)
        p.orderFrontRegardless()
    }

    // MARK: - Multi-window grid

    private func ensurePanel() -> NSPanel? {
        if let panel { return panel }
        let p = DockPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        // Allow the traffic-light buttons / cards to receive clicks (still a
        // non-activating panel, so the hovered app stays in front).
        p.ignoresMouseEvents = false
        panel = p
        return p
    }

    private func showMultiPreview(for app: NSRunningApplication, thumbs: [WindowThumb],
                                  iconRect: CGRect, dockRect: CGRect, isHorizontal: Bool) {
        let appName = app.localizedName ?? "App"
        let count = thumbs.count

        // Single-row layout (like Windows taskbar preview): all cards in one
        // horizontal row, centred above the Dock icon.  For vertical Docks the
        // row is rotated 90° (cards stack vertically).
        let panelW = previewSidePad * 2 + CGFloat(count) * previewCardW + CGFloat(count - 1) * previewGap
        let panelH = previewSidePad * 2 + previewHeaderH + previewCardH

        let view = DockPreviewRowView(
            thumbs: thumbs, appName: appName,
            onOpen:  { [weak self] cgID, ax in self?.openWindow(cgID, axWin: ax, app: app) },
            onClose: { [weak self] cgID, ax in self?.performWindowAction(cgID, axWin: ax, app: app, mode: .close) },
            onMin:   { [weak self] cgID, ax in self?.performWindowAction(cgID, axWin: ax, app: app, mode: .min) },
            onMax:   { [weak self] cgID, ax in self?.performWindowAction(cgID, axWin: ax, app: app, mode: .max) }
        )
        guard let p = ensurePanel() else { return }
        // Interactive preview: the panel MUST receive clicks (cards/controls).
        p.ignoresMouseEvents = false
        // Same first-click fix as the single-window card: without this, clicking
        // a preview card only made the panel key and the window never switched
        // until a second click.
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        p.contentView = host
        p.setContentSize(NSSize(width: panelW, height: panelH))
        positionPanel(iconRect: iconRect, dockRect: dockRect)
        p.orderFrontRegardless()
    }

    /// All *real* (AX) windows of `app` as capturable thumbnails.
    ///
    /// Uses **AX windows** (`kAXWindowsAttribute`) — not CG window list — so we
    /// only get user-visible NSWindows (Chrome shows 2–3 browser windows, NOT
    /// 12 per-tab/DevTools/render CG windows).  Each AX window is resolved to a
    /// CGWindowID for screenshot capture; minimized windows get their state from
    /// the AX `kAXMinimizedAttribute`.
    ///
    /// **Cross-app safety**: captures each window strictly by its real
    /// CGWindowID (via the WindowServer, which retains the backing store of
    /// minimized and hidden windows too), so no other window or app's content
    /// can ever leak into the tile ("串台").  When a window genuinely cannot be
    /// captured, its tile falls back to the app's icon.
    private static func windowThumbs(for app: NSRunningApplication) -> [WindowThumb] {
        // System apps (Launchpad, etc.) have no meaningful window content.
        guard AppClassifier.strategy(for: app) != .system else { return [] }
        let icon = app.icon

        // 1) On-screen windows of this exact app — one card each.  The shared
        //    `WindowList` enumerator cross-checks every CoreGraphics window
        //    against Accessibility (the "ghost veto" that drops stale leftover
        //    surfaces such as Chrome's phantom 4th window) and resolves the
        //    capture strategy from the window *owner name*, so a window owned by
        //    a Chrome helper still gets the browser crop that hides the URL bar.
        //    `expectedSize` feeds the structural coverage check in ImageUtil: a
        //    capture that only covers part of the window (clipped at a display
        //    edge) is rejected and the caller falls back to the icon.
        let wins = WindowList.onScreenWindows(filterPID: app.processIdentifier)
        var result: [WindowThumb] = wins.compactMap { pw -> WindowThumb? in
            let wid = pw.id
            let img = vsThumbnail(wid,
                                  windowSize: pw.frame.size, isMinimized: false, maxDim: 460)
            return WindowThumb(cgWindowID: wid, title: pw.title, image: img,
                               appIcon: icon, state: .live,
                               appName: app.localizedName ?? "",
                               axWindow: AX.windowWithID(wid))
        }

        // 2) Minimized windows are off-screen, so they never appear in the
        //    on-screen CG query — append them as their own cards too.
        let seen = Set(result.map { $0.cgWindowID })
        for win in AX.actualWindows(of: app) where AX.isMinimized(win) {
            guard let cgID = AX.cgWindowID(of: win), cgID != 0, !seen.contains(cgID) else { continue }
            let title = AX.title(of: win) ?? ""
            let img = vsThumbnail(cgID,
                                  windowSize: .zero, isMinimized: true, maxDim: 460)
            result.append(WindowThumb(cgWindowID: cgID, title: title, image: img,
                                      appIcon: icon, state: .minimized,
                                      appName: app.localizedName ?? "",
                                      axWindow: win))
        }

        // 3) ⌘H-hidden apps have no on-screen window at all — fall back to their
        //    AX windows (rendered as the app icon when no live frame exists).
        if result.isEmpty, app.isHidden {
            for win in AX.actualWindows(of: app) {
                guard let cgID = AX.cgWindowID(of: win), cgID != 0 else { continue }
                let title = AX.title(of: win) ?? ""
                let img = ThumbnailCache.lookupFront(of: app)?.image
                result.append(WindowThumb(cgWindowID: cgID, title: title, image: img,
                                          appIcon: icon, state: .hidden,
                                          appName: app.localizedName ?? "",
                                          axWindow: win))
            }
        }

        return result
    }

    private func openWindow(_ cgID: CGWindowID, axWin: AXUIElement?, app: NSRunningApplication) {
        // ⌘H-hidden app → bring it back before focusing the window, otherwise the
        // focus call lands on a hidden process and the window never appears.
        if app.isHidden { app.unhide() }
        // When no concrete window id is available (e.g. capture fell back to a
        // cached frame for a minimized app), `VSWindowActivator.activate` can
        // only front the *process* — leaving a minimized single-window app
        // (e.g. WeChat) invisible. Restore its front window first so it actually
        // appears. When cgID != 0 the activator itself un-minimizes, so this is
        // only a fallback for the no-id case.
        if cgID == 0,
           let wins = AX.windows(of: app),
           let front = wins.first,
           AX.isMinimized(front) {
            AX.setMinimized(front, false)
        }
        // Front the exact window (and the process) in one shot via vorssaint's
        // activator: fronts the process, sets it front, makes the window key, and
        // raises it inside the app's stack — which is what makes a single click
        // switch windows without needing a second click.
        VSWindowActivator.activate(pid: app.processIdentifier,
                                   windowID: cgID == 0 ? nil : cgID,
                                   appName: app.localizedName ?? "",
                                   retry: false)
        hide()
    }

    private enum WindowAction { case close, min, max }

    private func performWindowAction(_ cgID: CGWindowID, axWin: AXUIElement?, app: NSRunningApplication, mode: WindowAction) {
        defer { hide() }
        let target = axWin ?? AX.windowWithID(cgID)
        guard let ax = target else { return }
        switch mode {
        case .close: AX.closeWindow(ax)
        case .min:   if AX.isMinimized(ax) { AX.setMinimized(ax, false) } else { AX.minimizeWindow(ax) }
        case .max:   AX.maximizeWindow(ax)
        }
    }

    /// Place the card so it **sits flush on the Dock**, centred on the hovered
    /// icon — the same anchoring the system uses for Dock menus. Previously it
    /// floated above the *cursor*, so the card drifted around as the pointer
    /// moved and never lined up with the Dock bar.
    private func positionPanel(iconRect: CGRect, dockRect: CGRect) {
        guard let panel = panel else { return }
        let pw = panel.frame.width, ph = panel.frame.height
        let anchor = CGPoint(x: iconRect.midX, y: iconRect.midY)
        let screen = NSScreen.screens.first { NSScreen.cgFrame(of: $0).contains(anchor) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = NSScreen.cgFrame(of: screen)
        // Convert CG (top-left origin) → Cocoa (bottom-left origin).
        let dockCocoa = Coordinates.cgRectToCocoa(dockRect)
        let iconCocoa = Coordinates.cgRectToCocoa(iconRect)
        let edgeGap: CGFloat = 4   // hairline separation, still reads as "flush"

        var x: CGFloat
        var y: CGFloat
        if dockRect.width > dockRect.height {
            // Horizontal Dock: centre on the icon, stack on the Dock's outer edge.
            x = iconCocoa.midX - pw / 2
            let dockAtTop = dockRect.midY < sf.midY
            y = dockAtTop ? dockCocoa.minY - ph - edgeGap : dockCocoa.maxY + edgeGap
        } else {
            // Vertical Dock: sit beside it, vertically centred on the icon.
            let dockAtLeft = dockRect.midX < sf.midX
            x = dockAtLeft ? dockCocoa.maxX + edgeGap : dockCocoa.minX - pw - edgeGap
            y = iconCocoa.midY - ph / 2
        }
        // Clamp inside the screen so edge icons never push the card off-screen.
        x = min(max(x, screen.frame.minX + 6), screen.frame.maxX - pw - 6)
        y = min(max(y, screen.frame.minY + 6), screen.frame.maxY - ph - 6)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // Remember the panel's CG rect so handleMove() can tell "over the panel"
        // from "left the Dock" (the panel sits just above the Dock).
        let screenFrame = NSScreen.cgFrame(of: screen)
        panelCGRect = CGRect(x: screenFrame.minX + x,
                             y: screenFrame.maxY - y - ph,
                             width: pw, height: ph)
    }

    // MARK: - Traffic-light actions

    /// Close this app's front window; if it was the last one, quit the app.
    private func performClose(_ app: NSRunningApplication) {
        if let wins = AX.windows(of: app), let front = wins.first {
            AX.closeWindow(front)
            if wins.count <= 1 { app.forceTerminate() }
        } else {
            app.forceTerminate()
        }
        hide()
    }

    /// Minimize this app's front window (no-op if it has none / is hidden).
    private func performMinimize(_ app: NSRunningApplication) {
        if let wins = AX.windows(of: app), let front = wins.first {
            AX.minimizeWindow(front)
        }
        hide()
    }

    /// Bring this app's front window to the front and activate the app.
    private func performMaximize(_ app: NSRunningApplication) {
        if let wins = AX.windows(of: app), let front = wins.first {
            AX.maximizeWindow(front)
        }
        app.activate(options: .activateIgnoringOtherApps)
        hide()
    }

    private func hide() {
        guard panel != nil else { return }
        panel?.orderOut(nil)
        lastPID = 0
    }

    // MARK: - Window thumbnail capture

    /// Best-effort thumbnail + window title of the front-most normal window of
    /// `app`. Returns nil when the app has nothing to show (windowless, or
    /// hidden with no cached frame) — in that case NO preview is shown.
    /// For minimized / hidden apps a *replayed* cached frame (captured the moment
    /// the window vanished) is returned with the appropriate `state` so the card
    /// can label itself "已缩小 / 已隐藏".
    static func thumbnailInfo(for app: NSRunningApplication) -> (image: NSImage, title: String, state: WindowState, cgWindowID: CGWindowID)? {
        // One live attempt: cheap on-screen query first, then the broad scan (which
        // also returns minimized windows). `live` is non-nil whenever the app has a
        // window CoreGraphics can see. Doing this ONCE (instead of twice) keeps the
        // per-hover cost low.
        let live = Self.liveThumbnail(for: app)

        // 1) Genuinely on-screen window → show live and keep the cache fresh.
        if let live, live.state == .live {
            ThumbnailCache.store(pid: app.processIdentifier, title: live.title, image: live.image)
            return live
        }

        // 2) Minimized / hidden (no on-screen window). Prefer a *fresh* live capture
        //    of the minimized window when CoreGraphics can still produce one — that
        //    is the current state. But only if it's at least as detailed as what we
        //    already cached, so we never downgrade a nice full-window replay with a
        //    tiny dock tile. (Plan B safety net; Plan A — the minimize observer —
        //    is what normally keeps the cache current.)
        if let live, live.image.size.width > 8, live.image.size.height > 8 {
            if let cached = ThumbnailCache.lookupFront(of: app) {
                let cachedPx = Int(cached.image.size.width * cached.image.size.height)
                let livePx = Int(live.image.size.width * live.image.size.height)
                if livePx >= cachedPx {
                    ThumbnailCache.store(pid: app.processIdentifier, title: live.title, image: live.image)
                    return live
                }
                // Cached frame is the better full-window replay → keep it.
                // Same underlying window, so the live CG id is still valid to front it.
                return (cached.image, cached.title, app.isHidden ? .hidden : .minimized, live.cgWindowID)
            }
            // No cache at all → use the live (current) minimized frame.
            ThumbnailCache.store(pid: app.processIdentifier, title: live.title, image: live.image)
            return live
        }

        // 3) Last resort: replay the cached last *visible* frame. No live window id
        //    is available here → pass 0; openWindow() falls back to the app's front
        //    AX window so the click-to-open still works for a minimized app.
        if let cached = ThumbnailCache.lookupFront(of: app) {
            let state: WindowState = app.isHidden ? .hidden : .minimized
            return (cached.image, cached.title, state, 0)
        }
        return nil
    }

    /// Capture the front window of `app` via CG (on-screen OR minimized).
    ///
    /// Performance: an on-screen app is by far the common case, so we try the
    /// cheap `.optionOnScreenOnly` query first (a short list). Only when that
    /// finds nothing — i.e. the app is minimized and has no on-screen window —
    /// do we pay for the broader `.excludeDesktopElements` scan of every window
    /// on the system. This keeps the per-hover cost tiny for normal use.
    private static func liveThumbnail(for app: NSRunningApplication) -> (image: NSImage, title: String, state: WindowState, cgWindowID: CGWindowID)? {
        if let live = Self.frontWindow(of: app, opts: .optionOnScreenOnly) {
            return live
        }
        return Self.frontWindow(of: app, opts: [.excludeDesktopElements])
    }

    /// Return the largest qualifying window of `app` from a window-list query.
    private static func frontWindow(of app: NSRunningApplication, opts: CGWindowListOption) -> (image: NSImage, title: String, state: WindowState, cgWindowID: CGWindowID)? {
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let wins = list.filter {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier)
                && (($0[kCGWindowLayer as String] as? Int) ?? 0) == 0
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 1
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 1
        }
        let sorted = wins.sorted {
            (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0)
                > (($1[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0)
        }
        guard let first = sorted.first,
              let wid = first[kCGWindowNumber as String] as? UInt32 else { return nil }
        let title = (first[kCGWindowName as String] as? String) ?? ""

        // System apps: nothing useful to preview.
        if AppClassifier.strategy(for: app) == .system { return nil }

        // Expected size feeds the structural coverage check; a window captured
        // off every screen (minimized / other-Space) is exempt from it.
        let bounds = first[kCGWindowBounds as String] as? [String: CGFloat]
        let expectedSize = bounds.map { CGSize(width: $0["Width"] ?? 0, height: $0["Height"] ?? 0) }
        let isMinimized = opts != .optionOnScreenOnly && !Self.boundsAreOnScreen(first)

        // One resolver for every app class / state. It returns a genuine window
        // frame, or nil (→ caller shows the app icon). A minimized / hidden /
        // backgrounded web app (Baidu, etc.) is never live-captured here, so it
        // can never render a blank rectangle.
        guard let img = vsThumbnail(wid,
                                    windowSize: expectedSize ?? .zero,
                                    isMinimized: isMinimized, maxDim: 760) else {
            return nil  // no qualified frame available → caller falls back to icon
        }
        // An on-screen-only query can only yield live windows. The broader query
        // may also return minimized ones whose bounds sit off every screen.
        let state: WindowState = opts == .optionOnScreenOnly ? .live : (Self.boundsAreOnScreen(first) ? .live : .minimized)
        return (img, title, state, wid)
    }

    private static func boundsAreOnScreen(_ info: [String: Any]) -> Bool {
        guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else {
            return false
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        return NSScreen.screens.contains { NSScreen.cgFrame(of: $0).intersects(rect) }
    }

    func handle(action: String) {}
    func reload(config: Configuration) { enabled = config.previewEnabled }
    func uninstall() { hide() }
    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        else { installTap() }
    }
}

/// Borderless panel that deliberately does NOT become key.
///
/// Per the Macindow discipline (R3: "click once to raise the window"), a panel
/// that `canBecomeKey = true` swallows the first click to become key, forcing a
/// second click to reach the SwiftUI button — the classic "have to click twice"
/// bug. We keep the panel non-key and let `FirstMouseHostingView`'s
/// `acceptsFirstMouse` deliver the very first click straight to the traffic
/// lights / card tap target. The panel is shown with `orderFrontRegardless()`,
/// so it never needs key status to appear or receive clicks.
private class DockPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that acts on the **first** click.
///
/// By default AppKit swallows the click that brings a non-key window forward:
/// the panel becomes key and the event never reaches the view, so the user has
/// to click a second time to actually hit the button underneath.  That was the
/// entire "I have to click twice to switch window" bug — it had nothing to do
/// with the order of the raise/activate calls, which is why reordering them
/// never helped.  Returning true here delivers the very first click to SwiftUI.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// SwiftUI contents of the hover preview panel — same card style as the
/// Tab switcher: dark rounded card, thumbnail scaled to fit (never cropped),
/// app name + window title below, plus the macOS traffic-light controls
/// (close / minimize / maximize) overlaid on the thumbnail, just like the Tab.
struct DockPreviewView: View {
    let image: Image
    let appName: String
    let windowTitle: String
    let thumbW: CGFloat
    let thumbH: CGFloat
    let textH: CGFloat
    /// Non-nil when the thumbnail is a *replayed* frame (minimized / hidden app)
    /// rather than the live window — e.g. IadenteL10n.t("已缩小", "Minimized") / IadenteL10n.t("已隐藏", "Hidden").
    let badge: String?
    let onClose: () -> Void
    let onMin: () -> Void
    let onMax: () -> Void
    /// Clicking the preview image opens / fronts this window's main page — the
    /// same behaviour the multi-window grid already offers, now also on the
    /// single-window card so a one-window app is just as clickable.
    var onOpen: (() -> Void)? = nil
    /// Follows the system 浅色/深色 appearance automatically.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbW, height: thumbH)
                    .cornerRadius(8)

                // macOS traffic-light controls, top-left — same as the Tab card.
                HStack(spacing: 7) {
                    TrafficButton(color: .macClose, symbol: "xmark", action: onClose)
                    TrafficButton(color: .macMinimize, symbol: "minus", action: onMin)
                    TrafficButton(color: .macMaximize, symbol: "plus", action: onMax)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Capsule().fill(MTheme.chip(scheme)))
                .padding(9)
                .zIndex(2)
                .help(IadenteL10n.t("关闭 / 最小化 / 最大化", "Close / Minimize / Maximize"))

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .foregroundColor(.white)
                        .padding(6)
                        .zIndex(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(appName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MTheme.primaryText(scheme))
                    .lineLimit(1)
                if !windowTitle.isEmpty && windowTitle != appName {
                    Text(windowTitle)
                        .font(.system(size: 10))
                        .foregroundColor(MTheme.secondaryText(scheme))
                        .lineLimit(1)
                }
            }
            .frame(height: textH, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MTheme.panel(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(MTheme.hairline(scheme), lineWidth: 1)
                )
        )
        .shadow(radius: 8)
        // Tap anywhere on the card (image OR title) → open the window's main
        // page — same pattern as the working multi-window DockPreviewCard. We
        // attach this to the outer container (not the inner image), because a
        // gesture on a ZStack child is unreliable inside a panel that uses
        // acceptsFirstMouse, and was the reason single-window clicks did nothing.
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .help(IadenteL10n.t("点击打开该窗口", "Click to open this window"))
    }
}

/// Icon-only preview for system UIs / Finder: just the app icon + name, no
/// window frame and no traffic-light controls.
private struct DockIconPreviewView: View {
    let icon: Image
    let appName: String
    let iconSize: CGFloat
    let textH: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 6) {
            icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
            Text(appName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(MTheme.primaryText(scheme))
                .lineLimit(1)
        }
        .frame(height: iconSize + textH)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MTheme.panel(scheme))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(MTheme.hairline(scheme), lineWidth: 1))
        )
        .shadow(radius: 8)
    }
}

/// Multi-window Dock-hover preview: a **single horizontal row** of per-window
/// thumbnails, centred above the Dock icon (like Windows taskbar preview).
/// Each card is clickable to open/focus that exact window; hovering reveals
/// its close / minimize / maximize controls.
private struct DockPreviewRowView: View {
    let thumbs: [WindowThumb]
    let appName: String
    let onOpen: (CGWindowID, AXUIElement?) -> Void
    let onClose: (CGWindowID, AXUIElement?) -> Void
    let onMin: (CGWindowID, AXUIElement?) -> Void
    let onMax: (CGWindowID, AXUIElement?) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(IadenteL10n.t("\(appName) · \(thumbs.count) 个窗口", "\(appName) · \(thumbs.count) windows"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MTheme.primaryText(scheme))
                Spacer()
            }
            .padding(.horizontal, 2)

            // Single row — cards flow horizontally.
            HStack(spacing: previewGap) {
                ForEach(thumbs, id: \.cgWindowID) { thumb in
                    DockPreviewCard(thumb: thumb,
                                    onOpen:  { onOpen(thumb.cgWindowID, thumb.axWindow) },
                                    onClose: { onClose(thumb.cgWindowID, thumb.axWindow) },
                                    onMin:   { onMin(thumb.cgWindowID, thumb.axWindow) },
                                    onMax:   { onMax(thumb.cgWindowID, thumb.axWindow) })
                }
            }
        }
        .padding(previewSidePad)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MTheme.panel(scheme))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(MTheme.hairline(scheme), lineWidth: 1))
        )
        .shadow(radius: 8)
    }
}

/// A single window thumbnail inside the multi-window row. The whole card is
/// clickable (opens that window); the traffic lights appear on hover.
private struct DockPreviewCard: View {
    let thumb: WindowThumb
    let onOpen: () -> Void
    let onClose: () -> Void
    let onMin: () -> Void
    let onMax: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let img = thumb.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: previewCardInnerW, height: previewCardInnerH)
                        .cornerRadius(8)
                } else if let icon = thumb.appIcon {
                    // Fallback: show the app's own icon when screenshot is
                    // unavailable or unreliable (prevents cross-app contamination).
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(MTheme.chip(scheme))
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .opacity(0.85)
                    }
                    .frame(width: previewCardInnerW, height: previewCardInnerH)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MTheme.chip(scheme))
                        .frame(width: previewCardInnerW, height: previewCardInnerH)
                        .overlay(
                            Text(IadenteL10n.t("无预览", "No Preview"))
                                .font(.system(size: 10))
                                .foregroundColor(MTheme.secondaryText(scheme))
                        )
                }

                HStack(spacing: 6) {
                    TrafficButton(color: .macClose, symbol: "xmark", action: onClose)
                    TrafficButton(color: .macMinimize, symbol: "minus", action: onMin)
                    TrafficButton(color: .macMaximize, symbol: "plus", action: onMax)
                }
                .padding(6)
                .background(Capsule().fill(MTheme.chip(scheme)))
                .padding(7)
                .zIndex(2)
                .opacity(hovered ? 1 : 0)
                .help(IadenteL10n.t("关闭 / 最小化 / 最大化", "Close / Minimize / Maximize"))

                if thumb.state != .live {
                    Text(thumb.state == .hidden ? IadenteL10n.t("已隐藏", "Hidden") : IadenteL10n.t("已缩小", "Minimized"))
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .foregroundColor(.white)
                        .padding(6)
                        .zIndex(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(thumb.title.isEmpty ? thumb.appName : thumb.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(MTheme.primaryText(scheme))
                    .lineLimit(1)
            }
            .frame(height: previewCardTitleH, alignment: .leading)
        }
        .padding(previewCardPad)
        .frame(width: previewCardW, height: previewCardH)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovered ? MTheme.chip(scheme) : MTheme.panel(scheme))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onOpen() }
    }
}
