import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Helpers for detecting the Dock and the app under the cursor. All functions
/// are read-only and allocation-light so they are safe to call from inside an
/// event-tap callback (on a background run-loop thread).
///
/// 直接照搬自 Macindow 的 DockToggleFeature.swift（用户要求：Dock 相关功能
/// 完全复用 Macindow 代码，仅做 app 框架适配，不做视觉/逻辑改动）。
enum DockDetector {
    // Both event-tap callbacks run on the main run loop, so plain static
    // caches are safe here (no locking needed).
    private static var cachedItems: [(rect: CGRect, bundleID: String)] = []
    private static var itemsStamp = Date.distantPast
    private static var cachedDockRect: CGRect?
    private static var dockRectStamp = Date.distantPast

    /// Rectangle of the Dock bar, in CG (top-left origin) coordinates.
    /// Cached for 2 s — called on every mouse move by the hover preview.
    static func dockRect() -> CGRect? {
        if Date().timeIntervalSince(dockRectStamp) < 2.0 { return cachedDockRect }
        cachedDockRect = computeDockRect()
        dockRectStamp = Date()
        return cachedDockRect
    }

    /// The Dock bar is the strip of screen that `visibleFrame` excludes
    /// (besides the menu bar). Derived purely from screen geometry.
    ///
    /// WHY: the previous implementation picked the LARGEST window owned by
    /// the Dock process — but on modern macOS the full-screen wallpaper
    /// backstop is ALSO owned by the Dock, so `dockRect` covered the whole
    /// screen: hover/click detection then ran for every pixel, the expensive
    /// AX scans fired constantly, macOS disabled the taps, and both Dock
    /// features appeared completely dead.
    private static func computeDockRect() -> CGRect? {
        for s in NSScreen.screens {
            let f = NSScreen.cgFrame(of: s)
            let vf = NSScreen.cgVisibleFrame(of: s)
            let bottom = f.maxY - vf.maxY          // Dock at the bottom
            let left = vf.minX - f.minX          // Dock on the left
            let right = f.maxX - vf.maxX          // Dock on the right
            if bottom > 8 {
                return CGRect(x: f.minX, y: vf.maxY, width: f.width, height: bottom)
            }
            if left > 8 {
                return CGRect(x: f.minX, y: vf.minY, width: left, height: vf.height)
            }
            if right > 8 {
                return CGRect(x: vf.maxX, y: vf.minY, width: right, height: vf.height)
            }
        }
        // Auto-hidden Dock: fall back to the union of the icon frames.
        let icons = dockAppItems()
        guard !icons.isEmpty else { return nil }
        var u = icons[0].rect
        for it in icons.dropFirst() { u = u.union(it.rect) }
        return u.insetBy(dx: -8, dy: -8)
    }

    // MARK: - Dock icon enumeration (robust app detection)

    private static let dockBundleID = "com.apple.dock"

    /// All running-app Dock icons as (on-screen rect in CG space, bundle id).
    /// Cached for 0.8 s — the AX scan is too slow to run per-event (that is
    /// what got the click tap disabled by timeout before).
    static func dockAppItems() -> [(rect: CGRect, bundleID: String)] {
        if Date().timeIntervalSince(itemsStamp) < 0.8 { return cachedItems }
        itemsStamp = Date()
        cachedItems = scanDockItems()
        return cachedItems
    }

    private static func scanDockItems() -> [(rect: CGRect, bundleID: String)] {
        guard let dockPID = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == dockBundleID })?.processIdentifier else {
            return []
        }
        let dock = AXUIElementCreateApplication(dockPID)
        var items: [(CGRect, String)] = []
        // Dock AX tree: app → AXList → AXDockItem*. Depth-limited walk;
        // recurse only into containers (unlimited recursion over every child
        // was slow enough to stall the event tap).
        func visit(_ el: AXUIElement, depth: Int) {
            guard depth <= 3 else { return }
            guard let kids = attribute(el, kAXChildrenAttribute as CFString) as? [AXUIElement] else { return }
            for k in kids {
                if let f = frameOf(k), f.width > 4, let bid = bundleIDOf(k) {
                    items.append((f, bid))
                } else {
                    visit(k, depth: depth + 1)
                }
            }
        }
        visit(dock, depth: 0)
        return items
    }

    /// The running app whose Dock icon sits under `cgPoint`, or nil.
    static func appIconAt(cgPoint: CGPoint) -> NSRunningApplication? {
        let items = dockAppItems()
        guard let hit = items.first(where: { $0.rect.contains(cgPoint) }),
              let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == hit.bundleID }) else { return nil }
        return app
    }

    // MARK: - AX attribute helpers

    private static func attribute(_ el: AXUIElement, _ attr: CFString) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr, &v) == .success ? v : nil
    }

    private static func frameOf(_ el: AXUIElement) -> CGRect? {
        guard let pv = attribute(el, kAXPositionAttribute as CFString) as! AXValue?,
              let sv = attribute(el, kAXSizeAttribute as CFString) as! AXValue? else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &pos), AXValueGetValue(sv, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private static func bundleIDOf(_ el: AXUIElement) -> String? {
        // 1) Dock icons often expose the app's URL. Compare standardized
        //    paths (raw URL equality fails on trailing-slash differences).
        if let url = attribute(el, kAXURLAttribute as CFString) as? URL {
            let path = url.standardizedFileURL.path
            if let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
                return app.bundleIdentifier
            }
            if let bid = Bundle(url: url)?.bundleIdentifier { return bid }
        }
        // 2) Otherwise match by displayed title.
        if let title = attribute(el, kAXTitleAttribute as CFString) as? String,
           let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == title }) {
            return app.bundleIdentifier
        }
        return nil
    }
}
