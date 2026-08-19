import AppKit
import ApplicationServices
import CoreGraphics

/// A single, real, user-facing **on-screen** window as enumerated for preview
/// purposes.  Produced by `WindowList` and consumed by both the ⌘⌥Tab switcher
/// (`AppSwitcherFeature.collect`) and the Dock-hover preview
/// (`PreviewFeature.windowThumbs`).  Consolidating the enumeration here removes
/// the duplicated CoreGraphics scan + Accessibility cross-check that used to
/// live in both features, and keeps the "ghost veto" logic in one place.
///
/// The ghost veto (ported from Vorssaint's `WindowEnumerator`): a CoreGraphics
/// window whose owning app was successfully enumerated through Accessibility but
/// which Accessibility does NOT recognise as a real window is a stale leftover
/// surface (e.g. Chrome's phantom 4th window, a closed-tab residue) and is
/// dropped.  When Accessibility is unavailable the CG windows are kept, so a
/// transient AX hiccup never hides a real window.
struct PreviewWindow {
    let id: CGWindowID
    let pid: pid_t
    /// Window-server owner name (e.g. "Google Chrome", "Safari").  Used to pick
    /// the capture strategy for windows owned by a helper process whose bundle
    /// id is nil.
    let ownerName: String
    let title: String
    /// Real window bounds in CoreGraphics global coordinates (points).
    let frame: CGRect
    let isOnScreen: Bool
    /// Capture strategy resolved from the owner name first, then the bundle id.
    let strategy: AppCaptureStrategy
}

enum WindowList {
    /// Minimum real-window size.  Matches the Dock-hover filter (Width > 100,
    /// Height > 60) and is stricter than the old switcher area check, so no
    /// previously-shown window is dropped.
    private static let minWidth: CGFloat = 100
    private static let minHeight: CGFloat = 60

    /// Enumerate real, user-facing, **on-screen** windows.
    ///
    /// - Parameter filterPID: when set, only windows owned by that process are
    ///   returned (Dock-hover preview, which previews a single app).  When `nil`,
    ///   every app's windows are returned (switcher).
    ///
    /// Surfaces owned by the window server, our own UI, or the Dock are skipped.
    /// Layer-0 (normal) windows only.  Each surviving window carries its resolved
    /// capture `strategy` so callers can crop / decide capture correctly.
    static func onScreenWindows(filterPID: pid_t? = nil) -> [PreviewWindow] {
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // Per-pid Accessibility verdict, queried lazily and cached.  `recognized`
        // holds the real window ids AX acknowledges for this pid; an empty set
        // means "AX was unavailable / returned nothing → don't veto".
        var axRecognized: [pid_t: Set<CGWindowID>] = [:]
        var out: [PreviewWindow] = []
        var seen = Set<CGWindowID>()

        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let ww = bounds["Width"], let wh = bounds["Height"],
                  ww >= minWidth, wh >= minHeight,
                  let wid = w[kCGWindowNumber as String] as? UInt32, wid != 0,
                  !seen.contains(wid)
            else { continue }

            // Never preview the window-server / our own UI / the Dock itself.
            if owner == "Dock" || owner == "Window Server" || owner == "macall" { continue }

            let pidT = pid_t(pid)
            if let filterPID, pidT != filterPID { continue }

            // ---- Ghost veto -------------------------------------------------
            let recognized = axRecognized[pidT] ?? {
                var set = Set<CGWindowID>()
                if let app = NSRunningApplication(processIdentifier: pidT),
                   let wins = AX.windows(of: app) {
                    for win in wins where AX.isActualWindow(win) {
                        if let id = AX.cgWindowID(of: win) { set.insert(id) }
                    }
                }
                axRecognized[pidT] = set
                return set
            }()
            if !recognized.isEmpty, !recognized.contains(wid) { continue }

            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: ww, height: wh)
            let title = (w[kCGWindowName as String] as? String) ?? ""
            let isOnScreen = (w[kCGWindowIsOnscreen as String] as? Bool)
                ?? ((w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true)
            let strategy = AppClassifier.strategy(forOwnerName: owner)
                ?? (NSRunningApplication(processIdentifier: pidT)
                    .map { AppClassifier.strategy(for: $0) } ?? .native)

            seen.insert(wid)
            out.append(PreviewWindow(id: wid, pid: pidT, ownerName: owner,
                                     title: title, frame: frame,
                                     isOnScreen: isOnScreen, strategy: strategy))
        }
        return out
    }
}
