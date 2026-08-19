import AppKit
import Cocoa
import CoreGraphics
import ApplicationServices
import Foundation

/// Window-state classification used by the switcher and Dock-hover preview so
/// the UI can tell a *live* thumbnail from a *replayed* one (minimized / hidden).
enum WindowState {
    case live      // on-screen right now
    case minimized // in the Dock — replayed from a recent cached frame
    case hidden    // ⌘H hidden — only a cached last frame exists
}

/// Bounded, last-recently-used cache of window thumbnails used to *replay* a
/// preview for windows that can no longer be captured live:
///
///  - **Minimized** windows are usually *not* reliably capturable via CoreGraphics
///    once they live in the Dock, so we replay the last frame we grabbed while
///    the window was still visible.
///  - **Hidden (⌘H)** windows are NOT composited by the window server at all, so
///    a live capture is impossible — the cached last frame is the only option.
///
/// All stored images are already downscaled (≤720 px) by `ImageUtil`, and the
/// cache is capped at `limit` entries, so it stays tiny — this does NOT undo
/// the v10t memory optimizations.
///
/// Population is **event-driven only** (no periodic timer, per design):
/// on app deactivate, on ⌘H hide, and on every window minimize (via a per-app
/// AX observer). Each event captures the app's front window *while it is still
/// visible*, so the replayed frame is the one closest to the moment the user
/// switched away / hid / minimized.
final class ThumbnailCache {
    private struct Key: Hashable {
        let pid: pid_t
        let title: String
    }

    private static let limit = 32
    /// Precise per-window frame: (pid, window title) → image.
    private static var byWindow: [Key: NSImage] = [:]
    private static var order: [Key] = []

    // MARK: Window-id keyed cache (preferred)
    //
    // Keying a frame by window TITLE was a design mistake: a browser window's
    // title changes every time the user switches tab, so the same window kept
    // landing in a new slot (stale "previous tab" frames) while several windows
    // of one app could collide onto one entry (all three showing the same
    // picture).  A `CGWindowID` is stable for the whole life of the window and
    // unique across the system, so it is the correct key.  Now that
    // `AX.cgWindowID` returns the real number, every caller can use it.
    private static var byWid: [CGWindowID: NSImage] = [:]
    private static var widOwner: [CGWindowID: pid_t] = [:]
    private static var widOrder: [CGWindowID] = []
    /// App-level last frame: pid → (image, front-window title). This is what
    /// makes hidden-app previews possible, because once an app is hidden its
    /// AX window list is empty and we can no longer enumerate window titles.
    private static var byApp: [pid_t: (image: NSImage, title: String)] = [:]
    private static let queue = DispatchQueue(label: "com.macall.thumbcache")

    // Per-app AX observers that fire when a window is minimized.
    private static var observers: [pid_t: AXObserver] = [:]

    // MARK: - Store / lookup

    /// Store a freshly captured frame. Updates both the precise (pid,title) slot
    /// and the app-level representative frame (used for hidden-app fallback).
    static func store(pid: pid_t, title: String, image: NSImage) {
        let key = Key(pid: pid, title: title)
        queue.sync {
            if byWindow[key] == nil { order.append(key) }
            byWindow[key] = image
            byApp[pid] = (image, title)
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                byWindow[oldest] = nil
            }
        }
    }

    static func lookup(pid: pid_t, title: String) -> NSImage? {
        queue.sync { byWindow[Key(pid: pid, title: title)] }
    }

    /// Remember this window's last known frame, keyed by its window number.
    static func store(wid: CGWindowID, pid: pid_t, image: NSImage) {
        guard wid != 0 else { return }
        queue.sync {
            if byWid[wid] == nil { widOrder.append(wid) }
            byWid[wid] = image
            widOwner[wid] = pid
            while widOrder.count > limit, let oldest = widOrder.first {
                widOrder.removeFirst()
                byWid[oldest] = nil
                widOwner[oldest] = nil
            }
        }
    }

    /// The last frame captured for this exact window. Cannot return another
    /// window's image, because the key *is* the window.
    static func lookup(wid: CGWindowID) -> NSImage? {
        guard wid != 0 else { return nil }
        return queue.sync { byWid[wid] }
    }

    /// Best cached frame for an app:
    ///  1. a specific window we captured (by its title), else
    ///  2. the app-level last frame (works even when the app is hidden and AX
    ///     enumeration yields no windows).
    static func lookupFront(of app: NSRunningApplication) -> (image: NSImage, title: String)? {
        queue.sync {
            if let wins = AX.windows(of: app) {
                for w in wins {
                    if let t = AX.title(of: w),
                       let img = byWindow[Key(pid: app.processIdentifier, title: t)] {
                        return (img, t)
                    }
                }
            }
            if let rep = byApp[app.processIdentifier] { return rep }
            return nil
        }
    }

    /// App-level last frame (used to show a hidden app even when AX enumeration
    /// returns nothing).
    static func lookupApp(_ pid: pid_t) -> (image: NSImage, title: String)? {
        queue.sync { byApp[pid] }
    }

    // MARK: - Proactive capture (event-driven, no timer)

    /// Grab the front window of `app` *while it is still visible* — called the
    /// instant the app loses focus, gets hidden, or one of its windows is
    /// minimized. This is the only moment we can still capture a real frame.
    ///
    /// NOTE: deliberately NOT gated on `Permissions.isScreenRecordingTrusted()`.
    /// That preflight (`CGPreflightScreenCaptureAccess()`) returns false for a
    /// while after launch even when the user already granted Screen Recording, so
    /// gating here would skip our initial seeding and leave previews empty until
    /// TCC settles. We simply attempt the capture; if the permission is genuinely
    /// missing the call returns nil and nothing is stored (harmless).
    private static func captureFrontWindow(of app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard let wins = AX.windows(of: app), let win = wins.first else { return }
        guard let title = AX.title(of: win),
              let wid = AX.cgWindowID(of: win), wid != 0 else { return }
        if let img = ImageUtil.windowThumbnail(wid: wid, maxDim: 720) {
            store(pid: app.processIdentifier, title: title, image: img)
        }
    }

    /// Capture **every** visible window of `app` into the per-window cache.
    /// Used by the hide (⌘H) and deactivate handlers so multi-window apps
    /// have a cached frame for EACH window — not just the front one.
    private static func captureAllWindows(of app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let axWins = AX.actualWindows(of: app)
        guard !axWins.isEmpty else { return }
        for axWin in axWins {
            guard let wid = AX.cgWindowID(of: axWin) else { continue }
            guard let img = ImageUtil.windowThumbnail(wid: wid, maxDim: 720) else { continue }
            // App-level representative frame only. The per-window frame is now
            // owned by `WindowPreviewProvider`'s LRU cache (via `VSCaptureBridge`),
            // so writing it here too was a redundant, never-read copy that grew
            // with every minimize/hide/focus-loss event. Keeping only `byApp`
            // means the ⌘H-hidden fallback still works without the dead memory.
            if let title = AX.title(of: axWin) {
                store(pid: app.processIdentifier, title: title, image: img)
            }
        }
    }

    /// Capture the app's window the instant it is minimized. Unlike
    /// `captureFrontWindow` (which resolves an AX window → CGWindowID and is
    /// unreliable for a window mid-minimize-animation — that resolution frequently
    /// returns nil, so the cache never gets refreshed and the preview keeps showing
    /// the previous frame, e.g. the one captured during a Tab switch), this reads
    /// straight from the CoreGraphics window list for the app's PID. We prefer a
    /// window that is STILL on-screen (the minimize animation has only just begun,
    /// so it yields a large, recognizable frame) and fall back to the largest
    /// remaining window otherwise. This is Plan A of fixing "minimized preview
    /// shows a stale frame".
    private static func captureMinimizedWindow(of app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let wins = list.filter {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier)
                && (($0[kCGWindowLayer as String] as? Int) ?? 0) == 0
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 1
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 1
        }
        guard let first = wins.first else { return }
        // Prefer an on-screen (still-animating) window; else the largest one.
        let onScreen = wins.first { Self.boundsAreOnScreen($0) }
        let picked = onScreen ?? wins.max { a, b in
            (a[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0
                < (b[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0
        } ?? first
        guard let wid = picked[kCGWindowNumber as String] as? UInt32 else { return }
        guard let img = ImageUtil.windowThumbnail(wid: wid, maxDim: 720) else { return }
        let title = (picked[kCGWindowName as String] as? String) ?? ""
        store(pid: app.processIdentifier, title: title, image: img)
    }

    /// True when a CG window-info dict's bounds intersect any screen — i.e. the
    /// window is still visible / mid-animation rather than docked/minimized.
    private static func boundsAreOnScreen(_ info: [String: Any]) -> Bool {
        guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else {
            return false
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        return NSScreen.screens.contains { NSScreen.cgFrame(of: $0).intersects(rect) }
    }

    /// Subscribe to the events that mean "this app's window is about to vanish"
    /// and capture a fresh frame at exactly that moment. No periodic timer — we
    /// only capture on focus loss, hide, and minimize.
    static func startWatching() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication else { return }
            // Capture ALL windows (not just front) so multi-window apps have
            // a cached frame for every window after switching away.
            Self.captureAllWindows(of: app)
        }
        nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication else { return }
            // ⌘H hides EVERY window — cache them all so the Dock preview can
            // replay each one instead of falling back to the app icon.
            Self.captureAllWindows(of: app)
        }
        // Watch every running app for minimize events.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observeMinimize(of: app)
        }
        // And any app launched later.
        nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication else { return }
            observeMinimize(of: app)
        }
        // Free cached frames + the AX observer when an app quits. Without this the
        // per-app dictionaries and AX observers would accumulate for the entire
        // session as apps come and go — a slow memory / resource leak on machines
        // that stay up for days.
        nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication else { return }
            evict(pid: app.processIdentifier)
        }
        // Population is event-driven only (per the design note above): a fresh
        // frame is captured the instant an app deactivates, hides, or minimizes a
        // window. We deliberately do NOT eagerly capture every window at launch —
        // that startup burst used to spike CPU and memory at login, and it
        // duplicates the per-window frames that `WindowPreviewProvider`'s LRU
        // cache now owns. Hidden-app previews simply start empty and fill in on
        // the first relevant event (which for a hidden app is the ⌘H itself).
        Log.info("缩略图缓存：事件驱动（失焦/隐藏/缩小即抓帧，无定时器，启动不预抓）")
    }

    /// Register an AX observer on `app` so we are told the moment one of its
    /// windows is minimized. NSWorkspace has no minimize notification, so this is
    /// the only reliable way to capture a fresh frame right as the window leaves
    /// the screen.
    private static func observeMinimize(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let p = pid_t(Int(bitPattern: refcon))
            if let a = NSRunningApplication(processIdentifier: p) {
                ThumbnailCache.captureMinimizedWindow(of: a)
            }
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, cb, &obs) == .success, let observer = obs else { return }
        let appElem = AXUIElementCreateApplication(pid)
        // kAXWindowMiniaturizedNotification posts the string "AXWindowMiniaturized".
        let err = AXObserverAddNotification(observer, appElem,
                                           "AXWindowMiniaturized" as CFString,
                                           UnsafeMutableRawPointer(bitPattern: Int(pid)))
        guard err == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Drop every cached frame and tear down the AX observer for a quit app.
    /// Called from the `didTerminateApplicationNotification` handler so the cache
    /// and observer set stay bounded over a long-running session.
    private static func evict(pid: pid_t) {
        queue.sync {
            byApp.removeValue(forKey: pid)
            byWindow = byWindow.filter { $0.key.pid != pid }
            order.removeAll { $0.pid == pid }
            let goneWids = widOwner.filter { $0.value == pid }.map { $0.key }
            for w in goneWids {
                byWid.removeValue(forKey: w)
                widOwner.removeValue(forKey: w)
            }
            widOrder.removeAll { goneWids.contains($0) }
            if let obs = observers.removeValue(forKey: pid) {
                let appElem = AXUIElementCreateApplication(pid)
                AXObserverRemoveNotification(obs, appElem, "AXWindowMiniaturized" as CFString)
                let src = AXObserverGetRunLoopSource(obs)
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .defaultMode)
            }
        }
    }
}
