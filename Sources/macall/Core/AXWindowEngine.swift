import ApplicationServices
import Cocoa
import Foundation

// MARK: - Coordinate space helpers
//
// Accessibility `kAXPositionAttribute` expects coordinates in the **CG global
// space**: origin is the TOP-LEFT corner of the primary display. `NSScreen`
// exposes frames in **Cocoa space**: origin is the BOTTOM-LEFT corner. We must
// flip the Y axis when converting between the two. This is the single most
// common bug in window-tiling apps — without it windows get sent off-screen.
//
// 移植自 Macindow（MIT），沿用其验证过的写法。
extension NSScreen {
    /// This screen's full frame converted to CG global coordinates.
    static func cgFrame(of s: NSScreen) -> CGRect {
        let ph = NSScreen.screens[0].frame.maxY // height of the primary display
        let f = s.frame
        return CGRect(x: f.origin.x, y: ph - f.origin.y - f.height,
                      width: f.width, height: f.height)
    }

    /// This screen's visible frame (excluding menu bar + Dock) in CG global
    /// coordinates.
    static func cgVisibleFrame(of s: NSScreen) -> CGRect {
        let ph = NSScreen.screens[0].frame.maxY
        let v = s.visibleFrame
        return CGRect(x: v.origin.x, y: ph - v.origin.y - v.height,
                      width: v.width, height: v.height)
    }
}

/// Low-level wrappers around the Accessibility API. Every function is
/// defensive: failures return nil / false rather than throwing, so a single
/// stubborn app never breaks the whole tool.
enum AX {
    // MARK: - Read helpers

    static func attribute(_ element: AXUIElement, _ attr: CFString) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attr, &value)
        return err == .success ? value : nil
    }

    static func windows(of app: NSRunningApplication) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        return attribute(axApp, kAXWindowsAttribute as CFString) as! [AXUIElement]?
    }

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        return attribute(axApp, kAXFocusedWindowAttribute as CFString) as! AXUIElement?
    }

    // MARK: - Frame

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let posVal = attribute(element, kAXPositionAttribute as CFString) as! AXValue?,
              let sizeVal = attribute(element, kAXSizeAttribute as CFString) as! AXValue? else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &pos),
              AXValueGetValue(sizeVal, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    static func setFrame(_ element: AXUIElement, _ rect: CGRect) {
        var pos = rect.origin, size = rect.size
        guard let posV = AXValueCreate(.cgPoint, &pos),
              let sizeV = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posV)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeV)
    }

    static func setPosition(_ element: AXUIElement, _ p: CGPoint) {
        var pos = p
        guard let v = AXValueCreate(.cgPoint, &pos) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
    }

    static func setSize(_ element: AXUIElement, _ s: CGSize) {
        var size = s
        guard let v = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v)
    }

    /// Robust snap used by all tiling paths.
    ///
    /// Two real-world problems with a naive single pos+size write:
    /// 1. Some apps simply drop one of the two writes. Fix: a three-step write
    ///    (pos → size → pos), then verify and retry once.
    /// 2. Some apps enforce a MINIMUM size larger than the target zone. Chosen
    ///    policy: keep the app at its smallest allowed size and ANCHOR it to the
    ///    zone's edge.
    static func setFrameSnapped(_ win: AXUIElement, target: CGRect, visibleFrame vf: CGRect) {
        let tol: CGFloat = 6

        setPosition(win, target.origin)
        setSize(win, target.size)
        setPosition(win, target.origin)

        guard var actual = frame(of: win) else { return }

        if abs(actual.width - target.width) > tol || abs(actual.height - target.height) > tol {
            setSize(win, target.size)
            setPosition(win, target.origin)
            actual = frame(of: win) ?? actual
        }

        var x = actual.origin.x
        var y = actual.origin.y
        var moved = false

        if actual.width > target.width + tol {
            let band = vf.width * 0.10
            if target.midX < vf.midX - band {
                x = target.minX
            } else if target.midX > vf.midX + band {
                x = target.maxX - actual.width
            } else {
                x = target.midX - actual.width / 2
            }
            x = min(x, vf.maxX - actual.width)
            x = max(x, vf.minX)
            moved = true
        }
        if actual.height > target.height + tol {
            let band = vf.height * 0.10
            if target.midY < vf.midY - band {
                y = target.minY
            } else if target.midY > vf.midY + band {
                y = target.maxY - actual.height
            } else {
                y = target.midY - actual.height / 2
            }
            y = min(y, vf.maxY - actual.height)
            y = max(y, vf.minY)
            moved = true
        }
        if moved {
            setPosition(win, CGPoint(x: x, y: y))
            Log.info("窗口最小尺寸大于分区，已贴边放置（实际 \(Int(actual.width))x\(Int(actual.height)) vs 目标 \(Int(target.width))x\(Int(target.height))）")
        }
    }

    // MARK: - Minimize

    static func isMinimized(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXMinimizedAttribute as CFString) as? Bool) ?? false
    }

    static func setMinimized(_ element: AXUIElement, _ value: Bool) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, value as CFBoolean)
    }

    /// Maximize a window to fill the visible area of its screen.
    static func maximizeWindow(_ win: AXUIElement) {
        setFrame(win, visibleFrameForWindow(win))
    }

    // MARK: - Screen

    /// Visible frame (excluding menu bar + Dock) of the screen that holds the
    /// given window, in **CG global coordinates** (matching AX expectations).
    /// Falls back to the main screen.
    static func visibleFrameForWindow(_ element: AXUIElement) -> CGRect {
        guard let f = frame(of: element) else {
            return NSScreen.cgVisibleFrame(of: NSScreen.main ?? NSScreen.screens[0])
        }
        let center = CGPoint(x: f.midX, y: f.midY) // already in CG space
        let screen = NSScreen.screens.first { NSScreen.cgFrame(of: $0).contains(center) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        return NSScreen.cgVisibleFrame(of: screen)
    }

    // ===== window-preview integration (ported from Macindow) =====

    static func cgWindowID(of win: AXUIElement) -> CGWindowID? {
        var wid = CGWindowID(0)
        guard _AXUIElementGetWindow(win, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    static func subrole(of win: AXUIElement) -> String? {
        attribute(win, kAXSubroleAttribute as CFString) as? String
    }

    static func isActualWindow(_ win: AXUIElement) -> Bool {
        guard cgWindowID(of: win) != nil else { return false }
        if let sub = subrole(of: win) {
            let ok = sub == (kAXStandardWindowSubrole as String)
                || sub == (kAXDialogSubrole as String)
                || sub == "AXSystemDialog"
            if !ok { return false }
        }
        guard let f = frame(of: win), f.width > 100, f.height > 60 else { return false }
        return true
    }

    static func actualWindows(of app: NSRunningApplication) -> [AXUIElement] {
        (windows(of: app) ?? []).filter { isActualWindow($0) }
    }

    /// Look up an AXUIElement by its CGWindowID (exact reverse lookup).
    static func windowWithID(_ wid: CGWindowID) -> AXUIElement? {
        guard let pid = Self.pidForWindowID(wid) else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        guard let wins = attribute(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            return nil
        }
        return wins.first { cgWindowID(of: $0) == wid }
    }

    static func focusWindow(_ win: AXUIElement?, wid: CGWindowID, pid: pid_t) {
        if let win, isMinimized(win) { setMinimized(win, false) }
        if wid != 0 {
            var psn = ProcessSerialNumber()
            if GetProcessForPID(pid, &psn) == noErr {
                _SLPSSetFrontProcessWithOptions(&psn, wid, SLPSMode.userGenerated.rawValue)
                makeKeyWindow(&psn, wid)
            }
        } else if win != nil {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
        if let win { AXUIElementPerformAction(win, kAXRaiseAction as CFString) }
    }

    static func title(of win: AXUIElement) -> String? {
        attribute(win, kAXTitleAttribute as CFString) as? String
    }

    static func closeButton(of win: AXUIElement) -> AXUIElement? {
        attribute(win, kAXCloseButtonAttribute as CFString) as! AXUIElement?
    }

    static func minimizeButton(of win: AXUIElement) -> AXUIElement? {
        attribute(win, kAXMinimizeButtonAttribute as CFString) as! AXUIElement?
    }

    static func closeWindow(_ win: AXUIElement) {
        if let b = closeButton(of: win) { press(b) }
    }

    static func minimizeWindow(_ win: AXUIElement) {
        if let b = minimizeButton(of: win) { press(b) }
        else { setMinimized(win, true) }
    }

    static func raiseWindow(_ win: AXUIElement) {
        if isMinimized(win) { setMinimized(win, false) }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }

    /// 只把窗口抬到最前，**绝不改动最小化状态**。
    ///
    /// `raiseWindow` 会顺手把最小化的窗口捞回来，这在「用户主动点了一下」的场景是对的，
    /// 但周期性巡检（窗口置顶看门狗）绝对不能这么干——用户刚把钉住的窗口收进 Dock，
    /// 下一个 tick 就被强行弹回屏幕，表现就是窗口疯狂闪。
    static func raiseWindowKeepingMinimizeState(_ win: AXUIElement) {
        guard !isMinimized(win) else { return }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }

    static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private static func pidForWindowID(_ wid: CGWindowID) -> pid_t? {
        let opts = CGWindowListOption(arrayLiteral: .excludeDesktopElements)
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in list {
            if (w[kCGWindowNumber as String] as? UInt32) == wid {
                return (w[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
            }
        }
        return nil
    }

    static func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSScreen.cgFrame(of: $0).contains(point) }
    }
}
