import Cocoa
import CoreGraphics

/// macOS has two coordinate systems we touch:
///  - Cocoa / AX window positions: origin at bottom-left of the primary
///    display, Y grows upward.
///  - CGEvent / CGWindowList: origin at top-left of the primary display,
///    Y grows downward.
/// These helpers convert between them so Dock-hit testing (CG space) and
/// window geometry (Cocoa space) agree.
enum Coordinates {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoaToCG(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func cgToCocoa(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func cgRectToCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x,
               y: primaryHeight - r.origin.y - r.height,
               width: r.width,
               height: r.height)
    }
}
