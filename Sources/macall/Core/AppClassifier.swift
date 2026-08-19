import AppKit
import Foundation

/// How a given app's window preview should be captured, based on the rendering
/// technology it is built with. A single capture strategy cannot serve every
/// app well — this is the root cause of the "one size fits all" failures:
///
///  - `.native`   AppKit / SwiftUI / Qt / Java apps. `CGSHWCaptureWindowList`
///                returns the real frame in **every** state (on-screen,
///                minimized, hidden, other-Space). Live capture is always
///                correct → always use it.
///
///  - `.webBased` Electron / CEF / NW.js / heavy-WKWebView apps. Their content
///                is drawn by a GPU/compositor process that **stops compositing
///                when the app is not the frontmost process**. Re-capturing a
///                backgrounded web app yields a blank / white rectangle. The fix
///                is structural, not heuristic: capture LIVE only while the app
///                is frontmost, and once it is minimized / hidden / behind
///                another app, replay the cached frame from the last time it was
///                in front. Never attempt a fresh capture while it is in the
///                background.
///
///  - `.browser`  Chrome / Chromium / Firefox / Safari. Multi-window with a
///                distinct CGWindowID per window; live capture works in all
///                states (same as native, with stricter window filtering).
///
///  - `.system`   Launchpad, Notification Center, Dock, etc. No meaningful
///                window content to preview → icon only, skip capture entirely.
enum AppCaptureStrategy {
    case native
    case webBased
    case browser
    case system
}

struct AppClassifier {
    /// Detect the capture strategy for `app`. Cheap: a few file-existence
    /// checks on already-resolved bundle paths. Safe to call on every hover and
    /// every switcher-open.
    static func strategy(for app: NSRunningApplication) -> AppCaptureStrategy {
        let bid = app.bundleIdentifier ?? ""
        let fw = (app.bundleURL?.path ?? "") + "/Contents/Frameworks"

        // ---- system apps: no useful window content → icon only ----
        // Finder is included on purpose: its window capture frequently returns
        // the wrong region (the menu-bar / Control-Center area) instead of the
        // actual folder window, so we never live-capture it — just show its icon.
        if bid == "com.apple.finder"
            || bid == "com.apple.launchpad"
            || bid == "com.apple.launchpad.launcher"
            || bid == "com.apple.notificationcenterui"
            || bid == "com.apple.controlcenter"
            || bid == "com.apple.Spotlight"
            || bid == "com.apple.assistantd"
            || bid == "com.apple.dock"
            || bid == "com.apple.WindowManager"
            || bid == "com.apple.systemuiserver"
            || bid == "com.apple.loginwindow" { return .system }

        // ---- Electron (ships Electron Framework.framework) ----
        if FileManager.default.fileExists(atPath: fw + "/Electron Framework.framework") {
            return .webBased
        }
        // ---- CEF (Chromium Embedded Framework) ----
        if FileManager.default.fileExists(atPath: fw + "/Chromium Embedded Framework.framework") {
            return .webBased
        }
        // ---- NW.js ----
        if FileManager.default.fileExists(atPath: fw + "/nwjs Framework.framework") {
            return .webBased
        }

        // ---- browsers: live capture works in all states ----
        if bid.contains("com.google.Chrome")
            || bid.contains("Chromium")
            || bid.contains("org.mozilla.firefox")
            || bid == "com.apple.Safari"
            || bid == "com.apple.SafariTechPreview" { return .browser }

        // ---- everything else behaves natively ----
        return .native
    }

    /// Same classification as `strategy(for:)`, but driven by the **window owner
    /// name** reported by CoreGraphics rather than the process's bundle id.
    ///
    /// Needed because some apps (notably Chrome) occasionally expose extra
    /// on-screen windows owned by a *helper* process whose bundle id is nil.
    /// Routing that window through the default `.native` crop leaves the
    /// browser's tab strip + omnibox (which shows the URL) visible in the
    /// preview.  Matching on the owner name ("Google Chrome", "Safari", …)
    /// ensures those windows still get the browser crop that removes the URL bar.
    static func strategy(forOwnerName name: String) -> AppCaptureStrategy? {
        let n = name.lowercased()
        if n.contains("chrome") || n.contains("chromium")
            || n.contains("firefox") || n.contains("safari") { return .browser }
        if n.contains("launchpad") || n.contains("notification center")
            || n.contains("windowmanager") || n.contains("dock")
            || n.contains("finder") || n.contains("control center")
            || n.contains("spotlight") || n.contains("siri") { return .system }
        return nil
    }

    /// True when `app` is the currently frontmost process. Used so web-based apps
    /// are only live-captured while they are in front (their background frames
    /// are blank).
    static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// Whether a live capture of `app`'s window is expected to be *valid right
    /// now*.  This is the single decision point that keeps web-app previews from
    /// ever showing a blank/garbage rectangle:
    ///
    ///  - `.system`      → never (icon only)
    ///  - `.webBased`    → only while frontmost
    ///  - hinted (learned at runtime) → only while frontmost
    ///  - `.native`      → always
    ///  - `.browser`     → always (Chrome/Safari backing store is valid in every
    ///                     state, including legitimately-white pages)
    static func liveCaptureValid(for app: NSRunningApplication) -> Bool {
        liveCaptureValid(for: app, strategy: strategy(for: app))
    }

    /// Overload that honours a *caller-supplied* strategy.  Needed because the
    /// switcher derives the strategy from the window **owner name** (so a window
    /// owned by a Chrome helper / Launchpad still gets the right class even when
    /// its process bundle id is nil or unrecognised).  That owner-name strategy
    /// must also gate *whether* we capture — otherwise a Launchpad window flagged
    /// `.system` by name would still be live-captured (and show its blank frame).
    static func liveCaptureValid(for app: NSRunningApplication, strategy: AppCaptureStrategy) -> Bool {
        if isWebBasedHinted(app) { return isFrontmost(app) }
        switch strategy {
        case .system:   return false
        case .webBased: return isFrontmost(app)
        case .native, .browser: return true
        }
    }

    /// Apps whose window preview is unreliable or meaningless — always fall back
    /// to the app icon (never live-capture). Covers system UIs (Launchpad,
    /// Notification Center, Control Center, …) and apps like Finder whose
    /// captured frame is frequently the wrong region (e.g. the menu-bar / Control
    /// Center area instead of the actual window).
    static func isIconOnly(_ app: NSRunningApplication) -> Bool {
        strategy(for: app) == .system
    }

    /// Whether `app` currently owns at least one real, user-facing window that
    /// could be previewed.  Used to show the **app icon** for background / UI-less
    /// apps that sit in the Dock but have no main interface (menubar agents,
    /// helper processes, "Launchpad-like" apps) — the same situation as Launchpad,
    /// only without a known system bundle id.  Returns `true` (assume
    /// previewable) when the window query is unavailable, so a transient AX/CG
    /// hiccup never wrongly demotes a normal app to a bare icon.
    static func hasRealWindow(_ app: NSRunningApplication) -> Bool {
        if !AX.actualWindows(of: app).isEmpty { return true }
        guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        let pid = Int(app.processIdentifier)
        for w in list {
            guard let wpid = w[kCGWindowOwnerPID as String] as? Int,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let ww = b["Width"], let wh = b["Height"] else { continue }
            if wpid == pid && layer == 0 && ww * wh >= 4000 { return true }
        }
        return false
    }

    /// WKWebView-heavy apps can't be detected from bundle contents alone, so we
    /// let the capture layer promote an app to `.webBased` at runtime: the first
    /// time a backgrounded capture of its window comes back blank, record its pid
    /// so future captures replay the cache instead of re-capturing.
    static var webBasedHints: Set<pid_t> = []
    static func noteWebBased(_ pid: pid_t) { webBasedHints.insert(pid) }
    static func isWebBasedHinted(_ app: NSRunningApplication) -> Bool {
        webBasedHints.contains(app.processIdentifier)
    }
}
