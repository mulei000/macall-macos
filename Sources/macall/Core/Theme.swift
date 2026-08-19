import SwiftUI

/// Semantic palette for every Macindow overlay (Tab switcher, snap selector,
/// Dock hover preview, settings glyphs).
///
/// All colors are resolved from the ambient `ColorScheme`, which SwiftUI reads
/// from the hosting window's `effectiveAppearance`. Since none of our panels
/// pin an explicit `NSAppearance`, that value tracks the system 浅色/深色
/// setting — including live switches (and the "auto" schedule) while the app
/// is already running. So: no manual theme switch, no restart required.
///
/// RULE: never hard-code `Color.white` / `Color.black` in overlay UI — always
/// go through one of these helpers, otherwise the element becomes invisible in
/// one of the two appearances.
enum MTheme {
    /// Large floating panel background (Dock preview card, snap selector bar).
    static func panel(_ s: ColorScheme) -> Color {
        s == .dark ? Color(white: 0.09).opacity(0.93) : Color(white: 0.99).opacity(0.95)
    }

    /// Hairline border drawn on top of `panel`.
    static func hairline(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }

    /// Inner card / tile surface sitting on a panel or material background.
    static func surface(_ s: ColorScheme, active: Bool = false) -> Color {
        if active { return s == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10) }
        return s == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }

    /// Border of a tile surface.
    static func surfaceStroke(_ s: ColorScheme, active: Bool = false) -> Color {
        if active { return s == .dark ? Color.white.opacity(0.45) : Color.black.opacity(0.30) }
        return s == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    /// One cell of a split-pattern glyph inside a selector tile.
    static func glyph(_ s: ColorScheme, active: Bool) -> Color {
        if active { return Color.accentColor.opacity(s == .dark ? 0.95 : 0.85) }
        return s == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.18)
    }

    /// Translucent capsule behind small floating controls / hint text.
    static func chip(_ s: ColorScheme) -> Color {
        s == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.75)
    }

    static func primaryText(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.95) : Color.black.opacity(0.88)
    }

    static func secondaryText(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.55)
    }

    /// Placeholder block shown where a window thumbnail is unavailable.
    static func placeholder(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }
}
