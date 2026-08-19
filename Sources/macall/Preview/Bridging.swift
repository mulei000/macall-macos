// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint (ported into Macindow Preview/Vorssaint)
//
// Bridging layer: vorssaint's preview subsystem was copied verbatim into this
// folder, but it references a handful of symbols from vorssaint's wider app
// (Permissions, Defaults, AppInfo, AppFeature, PreviewSizing, WindowActivator,
// AXWindowResolver) plus a few non-preview helpers (WindowUseTracker,
// SpaceWindowBridge, SpaceHopSupport, GlobalShortcut, NSScreen helpers).
//
// Rather than drag half of vorssaint in, those are satisfied here with thin
// facades / minimal stubs backed by macall's own APIs. The preview capture,
// structural validation and window enumeration logic in the copied files is
// left untouched — this file is the ONLY place that adapts to macall.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Permissions (screen recording + accessibility)

struct VSPermissions {
    static let shared = VSPermissions()

    /// `CGPrefIsScreenCaptureEnabled` is an undocumented CoreGraphics function
    /// absent from some SDKs (not linkable against the 26.x SDK). Resolve it
    /// lazily via `dlsym` (RTLD_DEFAULT) so there is no hard link dependency;
    /// if it cannot be found we assume screen recording is allowed and let the
    /// capture itself fail gracefully (nil → app-icon fallback).
    private static let cgScreenCaptureEnabled: (() -> Bool)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let sym = dlsym(handle, "CGPrefIsScreenCaptureEnabled") else { return nil }
        typealias Fn = @convention(c) () -> Bool
        return unsafeBitCast(sym, to: Fn.self)
    }()

    /// True when the user granted Screen Recording (best-effort; `true` when the
    /// undocumented check is unavailable so capture can attempt and fail soft).
    var screenRecording: Bool { Self.cgScreenCaptureEnabled?() ?? true }

    /// Public Accessibility check.
    var accessibility: Bool { AXIsProcessTrusted() }
}

// MARK: - Defaults shim

enum VSDefaultsKey {
    static let windowPreviewExcludedApps = "windowPreviewExcludedApps"
    static let switcherWindowlessApps = "switcherWindowlessApps"
    static let switcherMergeTabs = "switcherMergeTabs"
    static let switcherCurrentSpaceOnly = "switcherCurrentSpaceOnly"
    static let dockPreviewEnabled = "dockPreviewEnabled"
    static let dockPreviewBackgroundOpacity = "dockPreviewBackgroundOpacity"
    static let previewSize = "previewSize"
}

enum VSDefaults {
    static let finderBundleIdentifier = "com.apple.finder"
    static let allowedPreviewSizes = ["small", "normal", "large", "xlarge"]

    /// Identity pass-through for the port: vorssaint sanitizes the exclusion list
    /// against a known-good set; macall has no such set, so we keep the raw
    /// list (exclusions are not part of the preview correctness work).
    static func sanitizedBundleIdentifierList(_ bundleIDs: [String]) -> [String] {
        bundleIDs
    }
}

// MARK: - App identity

enum VSAppInfo {
    static let name = "macall"
}

// MARK: - Feature availability (vorssaint gates Dock preview behind this)

struct VSAppFeatureFlag { let isAvailable: Bool }
enum AppFeature {
    static let dockPreview = VSAppFeatureFlag(isAvailable: true)
}

// MARK: - Preview sizing (scaled thumbnail size preference)

enum PreviewSizing {
    static func sanitized(_ value: String) -> String {
        VSDefaults.allowedPreviewSizes.contains(value) ? value : "normal"
    }

    static var scale: CGFloat {
        switch sanitized(UserDefaults.standard.string(forKey: VSDefaultsKey.previewSize) ?? "normal") {
        case "small":  return 0.75
        case "large":  return 1.4
        case "xlarge": return 1.8
        default:       return 1.0
        }
    }
}

// MARK: - AX window id resolver (reuses macall's _AXUIElementGetWindow)

enum AXWindowResolver {
    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}

// MARK: - Window activation (focus / minimize / close / raise)
//
// Implements the `WindowActivator` surface DockPreviewService calls, built on
// macall's AXWindowEngine + PrivateAPI focus primitives.

enum VSWindowActivator {

    /// Front a specific window of another process and make it key — mirrors
    /// macall's AX.focusWindow but takes a window id directly.
    private static func focusWindow(wid: CGWindowID, pid: pid_t) {
        let ax = AX.windowWithID(wid)
        if let ax, AX.isMinimized(ax) {
            AX.setMinimized(ax, false)
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: .activateIgnoringOtherApps)
        }
        var psn = ProcessSerialNumber()
        if GetProcessForPID(pid, &psn) == noErr {
            _SLPSSetFrontProcessWithOptions(&psn, wid, SLPSMode.userGenerated.rawValue)
            makeKeyWindow(&psn, wid)
        }
        if let ax {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
    }

    /// Bring the exact window backing `item` forward. App-only entries (no
    /// window id) just front the process.
    static func activate(_ item: VSSwitcherItem, retry: Bool = false) {
        guard let wid = item.previewWindowID else {
            if let app = NSRunningApplication(processIdentifier: item.pid) {
                app.activate(options: .activateIgnoringOtherApps)
            }
            return
        }
        focusWindow(wid: wid, pid: item.windowOwnerPID)
    }

    /// Front a specific window of a process by id (used to restore the session
    /// origin).
    static func activate(pid: pid_t, windowID: CGWindowID?, appName: String, retry: Bool) {
        if let wid = windowID, wid != 0 {
            focusWindow(wid: wid, pid: pid)
        } else if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    /// Live minimized state, or nil if the window cannot be resolved via AX.
    static func windowMinimizedState(windowID: CGWindowID, pid: pid_t) -> Bool? {
        guard let el = AX.windowWithID(windowID) else { return nil }
        return AX.isMinimized(el)
    }

    static func windowIsMinimized(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let el = AX.windowWithID(windowID) else { return false }
        return AX.isMinimized(el)
    }

    @discardableResult
    static func setWindowMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let el = AX.windowWithID(windowID) else { return false }
        AX.setMinimized(el, minimized)
        return true
    }

    /// Dispatch an AX close action. Returns true if the action was accepted.
    @discardableResult
    static func closeWindow(windowID: CGWindowID, appPID: pid_t, windowOwnerPID: pid_t) -> Bool {
        guard let el = AX.windowWithID(windowID) else { return false }
        return AXUIElementPerformAction(el, kAXCloseAction as CFString) == .success
    }

    /// The focused window id of a process, if Accessibility can read it.
    static func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &val) == .success,
              let win = val else { return nil }
        return AXWindowResolver.windowID(for: win as! AXUIElement)
    }
}

// MARK: - AX action constant (absent from the Swift overlay)

let kAXCloseAction = "AXClose" as CFString

// MARK: - NSScreen helpers (vorssaint's screen geometry helpers)

extension NSScreen {
    /// The screen currently under the mouse cursor.
    static var withMouse: NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(loc) }
    }
    /// The usable frame, inset for the menu bar / Dock — a benign stand-in for
    /// vorssaint's more precise pointer-aware variant. vorssaint exposes this as
    /// a static fallback (used when no screen matches a point).
    static var pointerVisibleFrame: NSRect { NSScreen.main?.visibleFrame ?? .zero }
}

// MARK: - GlobalShortcut stub (hotkey hint strings; not preview capture)

struct GlobalShortcut {
    var displayString: String { "" }
}

// MARK: - WindowUseTracker stub (MRU ordering)
//
// vorssaint orders switcher entries by most-recently-used windows. That needs
// WindowUseTracker + WindowUseOrder (another ~560 lines). For the preview port
// we keep the API surface but make it a no-op; ordering falls back to the
// window-server front-to-back order. Revisit in the joint refinement step if
// recent-use ordering is wanted.

extension WindowUseTracker {
    struct FrontToBack {}
}

class WindowUseTracker {
    static let shared = WindowUseTracker()
    var windows: [Any] = []
    var apps: [Any] = []
    static func frontToBack() -> FrontToBack { FrontToBack() }
    func reconcile(existingWindows: Set<CGWindowID>, frontToBack: FrontToBack, running: Set<pid_t>) {}
    func rank(of pid: pid_t) -> Int { 0 }
}

// MARK: - Space stubs (Spaces filtering adapted away for the port)
//
// vorssaint hides windows parked on hidden Spaces via Accessibility cross-checks.
// The supporting topology bridge is ~300 lines; the stubs return benign defaults
// (no hidden-space info, nothing excluded) so real windows are kept. Refine in
// the joint step if per-Space filtering is required.

enum SpaceWindowBridge {
    static func topology() -> Set<UInt64>? { nil }
    static func spaces(of windowID: CGWindowID) -> [UInt64] { [] }
    static func isExcludedFromWindowCycle(_ windowID: CGWindowID) -> Bool { false }
}

enum SpaceHopSupport {
    static func isParkedOnHiddenSpace(windowSpaces: [UInt64], visibleSpaces: Set<UInt64>) -> Bool { false }
}

// MARK: - L10n stub (localized UI strings for the Dock preview panel)
//
// vorssaint resolves these through its localization catalog. For the port we
// return plain labels; wire to macall's own strings in the joint step.

struct L10nStrings {
    let dockPreviewUnpinPanel = "Unpin Panel"
    let dockPreviewPinPanel = "Pin Panel"
    let dockPreviewClosePanel = "Close Panel"
    let dockPreviewPinned = "Pinned"
    let dockPreviewPreviousWindow = "Previous Window"
    let dockPreviewNextWindow = "Next Window"
    let dockPreviewOpenWindow = "Open Window"
    let dockPreviewRestoreWindow = "Restore Window"
    let dockPreviewMinimizeWindow = "Minimize Window"
    let dockPreviewCloseWindow = "Close Window"
}

final class L10n: ObservableObject {
    static let shared = L10n()
    let s = L10nStrings()
}

// MARK: - HUDBackdrop stub (frosted panel background)
//
// vorssaint's HUDBackdrop is a material + vibrancy backdrop. This minimal stand-in
// reproduces the rounded frosted surface the Dock preview panel draws on.

struct HUDBackdrop: View {
    let cornerRadius: CGFloat
    let opacity: Double
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThickMaterial.opacity(opacity))
    }
}

// MARK: - Shared vorssaint capture bridge
//
// The single, authoritative capture path used by BOTH the ⌘⌥Tab switcher and
// the Dock-hover preview (previously each feature carried its own near-identical
// `vsThumbnail` copy). Routes the capture through vorssaint's window-server path
// (`WindowPreviewProvider.captureViaWindowServer`, with the ScreenCaptureKit
// fallback inside the provider) and applies vorssaint's structural validation so
// a Stage Manager tilted strip or a window-server clipped edge slice is rejected
// and the caller falls back to the app icon instead of showing a broken frame.

enum VSCaptureBridge {
    /// How long a cached thumbnail stays "fresh" before the next preview
    /// re-captures it. The window-server capture is synchronous and comparatively
    /// cheap, but re-capturing *every* window on *every* hover/⌘⌥Tab open is what
    /// made the preview feel heavy — a 2 s window keeps the cache meaningful
    /// without showing visibly stale frames during rapid interaction.
    private static let cacheFreshness: TimeInterval = 2.0

    /// Capture `windowID` and return a downscaled `NSImage`, or `nil` when the
    /// capture is unavailable or fails vorssaint's structural checks.
    ///
    /// Performance: hits `WindowPreviewProvider`'s LRU cache first. A fresh hit is
    /// returned immediately (no window-server capture, no `alphaGrid` pass), so
    /// re-hovering an app or re-opening the switcher does not re-capture windows
    /// it already has a good thumbnail for. Only on a cache miss (or a stale
    /// entry) does it capture once and refile the result.
    /// - Parameters:
    ///   - windowID: the CoreGraphics window id to capture.
    ///   - windowSize: the window's real bounds; feeds the coverage check. Pass
    ///     `.zero` for minimized windows (they are exempt from the check).
    ///   - isMinimized: minimized windows are exempt from the coverage check and
    ///     may legitimately capture as a small tile.
    ///   - maxDim: longest-side downscale cap (e.g. 720 for the switcher, 760 /
    ///     460 for the Dock).
    static func thumbnail(windowID: CGWindowID,
                          windowSize: CGSize,
                          isMinimized: Bool,
                          maxDim: CGFloat) -> NSImage? {
        guard VSPermissions.shared.screenRecording else { return nil }

        // 1) LRU cache hit (fresh) → reuse, no capture, no validation passes.
        if let cached = WindowPreviewProvider.shared.cacheEntry(for: windowID,
                                                                maxAge: cacheFreshness) {
            let ns = NSImage(cgImage: cached,
                             size: NSSize(width: CGFloat(cached.width), height: CGFloat(cached.height)))
            return ns.scaledToMaxDimension(maxDim) ?? ns
        }

        // 2) Cache miss / stale → capture once.
        guard let cg = WindowPreviewProvider.captureViaWindowServer(windowID) else { return nil }
        if let grid = SwitcherSupport.alphaGrid(of: cg),
           SwitcherSupport.captureLooksTransformed(alphaGrid: grid) {
            return nil   // tilted strip artwork → fall back to app icon
        }
        if !isMinimized,
           !SwitcherSupport.captureCoversWindow(imageWidth: cg.width,
                                                imageHeight: cg.height,
                                                windowSize: windowSize) {
            return nil   // only a clipped slice came back → fall back to app icon
        }
        // Refill the cache so the next peek is free; the byte/count budget and
        // memory-pressure purge in `WindowPreviewProvider` keep this bounded.
        WindowPreviewProvider.shared.storeCached(cg, for: windowID)
        let ns = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ns.scaledToMaxDimension(maxDim) ?? ns
    }
}
