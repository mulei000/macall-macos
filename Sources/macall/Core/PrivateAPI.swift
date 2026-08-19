import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - Private system APIs
//
// macOS exposes no *public* way to do three things this app fundamentally needs:
//
//   1. Ask "which CGWindowID is this AXUIElement?"  — `kAXIdentifier` is an
//      app-defined accessibility string, NOT the window number, and returns nil
//      for most apps.  Without the real number every screenshot has to *guess*
//      which window it is capturing (frame/title matching), which is exactly what
//      produced the cross-app "wrong preview" bugs in v10.31–v10.37.
//   2. Screenshot a window that is minimized or hidden.  The public
//      `CGWindowListCreateImage` returns an empty image for those, which is why
//      previews degraded to the bare app icon after ⌘H / minimize.
//   3. Focus one specific window of another app.  `NSRunningApplication.activate`
//      only fronts the *app*, and an AX raise on an inactive app is silently
//      dropped — the "have to click twice" symptom.
//
// Every symbol below is a long-standing, stable private API used by the major
// open-source macOS window managers (AltTab, yabai, Hammerspoon, Rectangle).
// They are bound with `@_silgen_name`, so there is no dlopen/dlsym at runtime and
// no App Store review exposure (this app is self-signed and distributed directly).
// All of them exist since macOS 10.10+; each is annotated with its provenance.

// MARK: 1. AXUIElement → CGWindowID  (ApplicationServices.HIServices)

/// Returns the real CGWindowID backing an AXUIElement.  This is *the* correct
/// bridge between the Accessibility world (where we enumerate an app's windows)
/// and the CoreGraphics world (where we screenshot and focus them).
/// * macOS 10.10+ — used by AltTab, yabai, Hammerspoon.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: 2. WindowServer screenshots  (SkyLight)

typealias CGSConnectionID = UInt32

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    /// Capture the whole window even when partially clipped/obscured.
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    /// 1× capture. On Retina `bestResolution` costs 4× the memory for pixels we
    /// immediately downscale away, so we always ask for nominal.
    static let nominalResolution = CGSWindowCaptureOptions(rawValue: 1 << 9)
    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    /// Full-size frame even when Stage Manager would otherwise skew it.
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

/// The process-wide WindowServer connection required by every SkyLight call.
/// * macOS 10.10+
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

/// Screenshot windows by ID, straight from the WindowServer.
///
/// Unlike the public `CGWindowListCreateImage`, this **works for minimized
/// windows, hidden (⌘H) windows and windows on other Spaces** — it reads the
/// WindowServer's retained backing store rather than the visible framebuffer.
/// It is the only API that can do so, and it is why v11 no longer needs to
/// replay stale cached frames for minimized windows.
/// * macOS 10.10+ — AltTab's primary capture path below macOS 26.
@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(_ cid: CGSConnectionID,
                            _ windowList: UnsafeMutablePointer<CGWindowID>,
                            _ windowCount: UInt32,
                            _ options: CGSWindowCaptureOptions) -> Unmanaged<CFArray>

/// Window level (normal windows are 0; panels/tooltips/menus are not).
/// * macOS 10.10+
@_silgen_name("CGSGetWindowLevel") @discardableResult
func CGSGetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID,
                       _ level: UnsafeMutablePointer<CGWindowLevel>) -> CGError

/// Set a window's level (normal windows are 0; floating/status levels float it
/// above others). This is the WindowServer-level "always on top" primitive used
/// by window managers — no Accessibility permission required.
/// * macOS 10.10+
@_silgen_name("CGSSetWindowLevel") @discardableResult
func CGSSetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID, _ level: CGWindowLevel) -> CGError

/// Shared connection, resolved once.
let CGS_CONNECTION = CGSMainConnectionID()

// MARK: 3. Cross-app window focus  (SkyLight + Processes)
//
// `_SLPSSetFrontProcessWithOptions` and `SLPSPostEventRecordTo` live in
// SkyLight, but on modern macOS their symbols are NOT present in any linkable
// .tbd — SkyLight ships inside the dyld shared cache and its on-disk stub has no
// symbol table, so the linker cannot resolve them (the CGS* and
// `_AXUIElementGetWindow` symbols link fine only because CoreGraphics /
// ApplicationServices re-export them).  We therefore resolve these two at
// runtime via `dlsym` from the already-loaded SkyLight image.  SkyLight is part
// of every GUI process, so the symbols are guaranteed to be present by the time
// any of our code runs.

/// Flags for `_SLPSSetFrontProcessWithOptions` (yabai's `kCPS*` constants).
enum SLPSMode: UInt32 {
    /// Bring every window of the app forward.
    case allWindows = 0x100
    /// Mark the switch as user-initiated — without this macOS may suppress it.
    case userGenerated = 0x200
    /// Front the process without raising any window.
    case noWindows = 0x400
}

typealias _SLPSSetFrontProcessWithOptionsFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
) -> CGError

typealias _SLPSPostEventRecordToFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
) -> CGError

/// Resolve a SkyLight symbol by name from the global symbol space. SkyLight is
/// always loaded into a GUI process, so this never fails at runtime.
/// `RTLD_DEFAULT` is `(void*)-2`; its dlfcn macro is unavailable in Swift, so we
/// build the pointer directly.
private func skyLightSymbol<T>(_ name: String) -> T? {
    let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

private let _slpsSetFrontProcessWithOptionsPtr: _SLPSSetFrontProcessWithOptionsFn? = {
    skyLightSymbol("_SLPSSetFrontProcessWithOptions")
}()

private let _slpsPostEventRecordToPtr: _SLPSPostEventRecordToFn? = {
    skyLightSymbol("SLPSPostEventRecordTo")
}()

/// Front a process **and** raise one specific window of it (by `wid`).
/// This is what makes single-click window switching actually work: the public
/// `activate()` can only front the app, leaving whichever window *it* considers
/// front on top.
@discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                     _ wid: CGWindowID, _ mode: SLPSMode.RawValue) -> CGError {
    guard let fn = _slpsSetFrontProcessWithOptionsPtr else { return CGError.cannotComplete }
    return fn(psn, wid, mode)
}

/// Post a raw event record to the WindowServer (used by `makeKeyWindow`).
@discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                           _ bytes: UnsafeMutablePointer<UInt8>) -> CGError {
    guard let fn = _slpsPostEventRecordToPtr else { return CGError.cannotComplete }
    return fn(psn, bytes)
}

/// PID → ProcessSerialNumber. Deprecated publicly, still present as a private
/// symbol and still the only way to build the psn the SLPS calls want.
/// * macOS 10.9+
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// MARK: 4. System appearance + lock screen  (SkyLight / login.framework)
//
// Both replace far less reliable shell/AppleScript paths:
//
//   * Dark mode used to go through System Events' `appearance preferences`.
//     That requires the user to grant *Automation* permission to System Events,
//     silently fails when the AppleEvent is denied, and takes ~300 ms to launch
//     the scripting bridge. `SLSSetAppearanceThemeLegacy` is the exact call the
//     Control Center switch makes — instant, permission-free.
//   * Lock screen used to shell out to `CGSession -suspend`, which is *fast user
//     switching* (it switches to the login window), not a lock. On a Mac with a
//     single account and auto-login it can bounce right back, and it does not
//     honour the "require password after screen saver" grace period.
//     `SACLockScreenImmediate` is the entry point the ⌃⌘Q menu item uses.

/// True when the system is currently in dark mode. * macOS 10.14+
private typealias SLSGetThemeFn = @convention(c) () -> Bool
/// Set dark (`true`) / light (`false`). * macOS 10.14+
private typealias SLSSetThemeFn = @convention(c) (Bool) -> Void
/// Whether appearance follows the sunrise/sunset "Auto" setting. * macOS 10.14+
private typealias SLSSetAutoFn = @convention(c) (Bool) -> Void

private let _slsGetTheme: SLSGetThemeFn? = skyLightSymbol("SLSGetAppearanceThemeLegacy")
private let _slsSetTheme: SLSSetThemeFn? = skyLightSymbol("SLSSetAppearanceThemeLegacy")
private let _slsGetAuto: SLSGetThemeFn? = skyLightSymbol("SLSGetAppearanceThemeSwitchesAutomatically")
private let _slsSetAuto: SLSSetAutoFn? = skyLightSymbol("SLSSetAppearanceThemeSwitchesAutomatically")

/// Reads / writes the system appearance through the WindowServer.
///
/// `available` is false only if Apple ever removes the symbols, in which case
/// callers fall back to AppleScript.
enum SystemAppearance {
    static var available: Bool { _slsSetTheme != nil }

    static var isDark: Bool { _slsGetTheme?() ?? (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark") }

    /// Toggling while "Auto" is on has to disable Auto first, otherwise the
    /// WindowServer reverts our value at the next scheduled transition.
    @discardableResult
    static func toggle() -> Bool {
        guard let setTheme = _slsSetTheme else { return false }
        if _slsGetAuto?() == true { _slsSetAuto?(false) }
        setTheme(!isDark)
        return true
    }
}

/// `int SACLockScreenImmediate(void)` — lives in login.framework, which is *not*
/// linked into a normal app, so it needs an explicit dlopen (unlike SkyLight,
/// which is already resident in every GUI process).
private typealias SACLockScreenFn = @convention(c) () -> Int32

private let _sacLockScreen: SACLockScreenFn? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
          let sym = dlsym(handle, "SACLockScreenImmediate") else { return nil }
    return unsafeBitCast(sym, to: SACLockScreenFn.self)
}()

/// Lock the screen immediately. Returns false when the symbol is unavailable so
/// the caller can fall back to `CGSession -suspend`.
@discardableResult
func lockScreenImmediately() -> Bool {
    guard let fn = _sacLockScreen else { return false }
    return fn() == 0
}

/// Byte layout of the synthetic `CGSEventRecord` posted by `makeKeyWindow`.
/// Offsets reverse-engineered from CGSInternal's CGSEvent.h; identical to the
/// ones yabai and Hammerspoon use.
private enum MakeKeyWindowEvent {
    /// The record is 0xf8 bytes, but we allocate 0x100 zeroed bytes: on
    /// macOS 14.7.4+ the WindowServer's encoder reads slightly past the record
    /// and would abort on heap garbage. yabai allocates the same 0x100.
    static let bufferSize = 0x100
    static let lengthOffset = 0x04
    static let recordLength: UInt8 = 0xf8
    static let eventTypeOffset = 0x08
    static let leftMouseDown: UInt8 = 0x01
    static let leftMouseUp: UInt8 = 0x02
    /// Window-relative click point. Aimed just *outside* the top-left corner so
    /// the window becomes key without the synthetic click hit-testing onto any
    /// real content (a (0,0) click would press whatever chrome sits there).
    static let windowLocationOffset = 0x20
    static let offContentPoint = CGPoint(x: -1, y: -1)
    /// Target CGWindowID — the event is routed by id, not by the point above.
    static let windowIdOffset = 0x3c
    /// Purpose undocumented; yabai and Hammerspoon both set it to 0x10.
    static let unknownFlagOffset = 0x3a
    static let unknownFlagValue: UInt8 = 0x10
}

/// Make `wid` the **key** window of its app by posting a synthetic
/// mouse-down/up pair to the WindowServer. No public API can move key focus
/// across app boundaries. Ported from yabai's `window_manager_make_key_window`.
func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
    var wid = wid
    var point = MakeKeyWindowEvent.offContentPoint
    var bytes = [UInt8](repeating: 0, count: MakeKeyWindowEvent.bufferSize)
    bytes[MakeKeyWindowEvent.lengthOffset] = MakeKeyWindowEvent.recordLength
    bytes[MakeKeyWindowEvent.unknownFlagOffset] = MakeKeyWindowEvent.unknownFlagValue
    memcpy(&bytes[MakeKeyWindowEvent.windowIdOffset], &wid, MemoryLayout<CGWindowID>.size)
    memcpy(&bytes[MakeKeyWindowEvent.windowLocationOffset], &point, MemoryLayout<CGPoint>.size)
    bytes[MakeKeyWindowEvent.eventTypeOffset] = MakeKeyWindowEvent.leftMouseDown
    SLPSPostEventRecordTo(&psn, &bytes)
    bytes[MakeKeyWindowEvent.eventTypeOffset] = MakeKeyWindowEvent.leftMouseUp
    SLPSPostEventRecordTo(&psn, &bytes)
}
