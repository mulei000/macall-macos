import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - Key codes (macOS virtual keycodes)

enum VK {
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let a: UInt16 = 0
    static let c: UInt16 = 8
    static let s: UInt16 = 1
    static let l: UInt16 = 37
    static let v: UInt16 = 9
    static let m: UInt16 = 46
    static let o: UInt16 = 31
    static let p: UInt16 = 35
    static let r: UInt16 = 15
    static let d1: UInt16 = 18
    static let d2: UInt16 = 19
    static let d3: UInt16 = 20
    static let d4: UInt16 = 21
    static let leftBracket: UInt16 = 33
    static let rightBracket: UInt16 = 30
    static let backslash: UInt16 = 42
    static let space: UInt16 = 49
    static let tab: UInt16 = 48
    static let q: UInt16 = 12
    static let d: UInt16 = 2
    static let e: UInt16 = 14
    static let t: UInt16 = 17
    static let b: UInt16 = 11
    static let f: UInt16 = 3
    static let g: UInt16 = 5
    static let h: UInt16 = 4
    static let i: UInt16 = 34
    static let k: UInt16 = 40
    static let j: UInt16 = 38
    static let x: UInt16 = 7
    static let w: UInt16 = 13
    static let d5: UInt16 = 22
    static let n: UInt16 = 45
    static let z: UInt16 = 6
    static let u: UInt16 = 32
    static let y: UInt16 = 16
    static let comma: UInt16 = 43
    static let period: UInt16 = 47
    static let slash: UInt16 = 44
    static let quote: UInt16 = 39
    static let semicolon: UInt16 = 41
}

// A keyboard shortcut: virtual keycode + modifier flags (command/control/option/shift).
struct HotkeyCombo: Hashable {
    let keyCode: UInt16
    let flags: UInt32
}

// Serializable form stored in config.
struct HotkeySpec: Codable, Hashable {
    let keyCode: UInt16
    let flags: UInt32

    func toCombo() -> HotkeyCombo {
        HotkeyCombo(keyCode: keyCode, flags: flags)
    }
}

// Build a flags bitmask from CGEventFlags we care about.
func mask(_ flags: CGEventFlags...) -> UInt32 {
    flags.reduce(UInt32(0)) { acc, f in acc | UInt32(f.rawValue) }
}

let F_CMD = CGEventFlags.maskCommand
let F_CTRL = CGEventFlags.maskControl
let F_OPT = CGEventFlags.maskAlternate
let F_SHIFT = CGEventFlags.maskShift

// Modifiers we consider when matching a shortcut.
let RELEVANT_MODS: UInt32 = UInt32(F_CMD.rawValue) | UInt32(F_CTRL.rawValue) | UInt32(F_OPT.rawValue) | UInt32(F_SHIFT.rawValue)

// Extract only the relevant modifier bits from a live event.
func relevantFlags(_ event: CGEvent) -> UInt32 {
    UInt32(event.flags.rawValue) & RELEVANT_MODS
}

/// 把修饰符位掩码转成 ⌘⌃⌥⇧ 形式的字符串，用于设置界面展示。
func modifierSymbols(_ flags: UInt32) -> String {
    var s = ""
    if flags & UInt32(F_CMD.rawValue) != 0 { s += "⌘" }
    if flags & UInt32(F_CTRL.rawValue) != 0 { s += "⌃" }
    if flags & UInt32(F_OPT.rawValue) != 0 { s += "⌥" }
    if flags & UInt32(F_SHIFT.rawValue) != 0 { s += "⇧" }
    return s
}

/// 把持久化的 HotkeySpec 转成设置界面展示用的字符串，例如 ⌃⌥X。
/// 快捷键被用户自定义后会自动反映，避免界面写死默认组合。
func hotkeyDisplayString(_ spec: HotkeySpec) -> String {
    modifierSymbols(spec.flags) + KeyNames.display(for: spec.keyCode)
}

// MARK: - Human-readable key names

/// Turns a virtual keycode into something a person can read.
///
/// 解析当前键盘布局下该物理键产生的实际字符，因此 ⌥D 会显示为「⌥D」，
/// 且 AZERTY/QWERTZ 等布局差异天然兼容。
enum KeyNames {
    private static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: IadenteL10n.t("空格", "Space"), 51: "⌫", 53: "esc",
        71: "clear", 76: "⌤", 114: IadenteL10n.t("帮助", "Help"), 115: "home", 116: IadenteL10n.t("上翻页", "Page Up"),
        117: "⌦", 119: "end", 121: IadenteL10n.t("下翻页", "Page Down"),
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let ansi: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
        65: IadenteL10n.t("小数点", "Decimal"), 67: "*", 69: "+", 75: "/", 78: "-", 81: "=",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4",
        87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
    ]

    static func display(for code: UInt16) -> String {
        if let s = special[code] { return s }
        if let c = layoutCharacter(for: code) { return c }
        if let a = ansi[code] { return a }
        return IadenteL10n.t("键 \(code)", "Key \(code)")
    }

    private static func layoutCharacter(for code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        // ⚠️ TISGetInputSourceProperty 返回的是内部属性数据，不是 +1 retained。
        // 用 takeRetainedValue() 会多 release 一次，导致 UCKeyTranslate 时访问已释放
        // 的 CFData -> SIGSEGV。必须用 takeUnretainedValue()。
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status: OSStatus = data.withUnsafeBytes { buf in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s.uppercased()
    }
}
