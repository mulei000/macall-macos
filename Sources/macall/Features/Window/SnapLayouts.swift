import CoreGraphics
import Foundation

enum SnapKind: String {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, rightThird, centerThird
    case leftTwoThirds, rightTwoThirds
    case maximize, center
}

/// Computes the target frame for a snap action inside a screen's visible area.
///
/// All math is done in **CG global coordinates** (origin = top-left of the
/// primary display, Y increases downward) so it matches exactly what the
/// Accessibility `kAXPositionAttribute` expects.
///
/// 移植自 Macindow（MIT），沿用其验证过的写法。
enum SnapLayout {
    /// - Parameter gap: spacing, in points, inserted *between* adjacent tiles.
    ///   Each tile is inset by `gap/2` on every side, so two neighbouring
    ///   tiles end up exactly `gap` apart, and every split is perfectly equal.
    static func compute(kind: SnapKind, visibleFrame vf: CGRect, gap: CGFloat) -> CGRect {
        let W = vf.width, H = vf.height, x0 = vf.minX, y0 = vf.minY
        let g = max(0, gap)
        let pad = g / 2
        let tiled = { (r: CGRect) -> CGRect in r.insetBy(dx: pad, dy: pad) }

        switch kind {
        // --- Halves (equal halves, separated by `gap`) ---
        case .leftHalf:    return tiled(CGRect(x: x0,        y: y0,        width: W / 2, height: H))
        case .rightHalf:   return tiled(CGRect(x: x0 + W / 2, y: y0,        width: W / 2, height: H))
        case .topHalf:     return tiled(CGRect(x: x0,        y: y0,        width: W, height: H / 2))
        case .bottomHalf:  return tiled(CGRect(x: x0,        y: y0 + H / 2, width: W, height: H / 2))

        // --- Quarters (equal quadrants) ---
        case .topLeft:     return tiled(CGRect(x: x0,        y: y0,        width: W / 2, height: H / 2))
        case .topRight:    return tiled(CGRect(x: x0 + W / 2, y: y0,        width: W / 2, height: H / 2))
        case .bottomLeft:  return tiled(CGRect(x: x0,        y: y0 + H / 2, width: W / 2, height: H / 2))
        case .bottomRight: return tiled(CGRect(x: x0 + W / 2, y: y0 + H / 2, width: W / 2, height: H / 2))

        // --- Thirds (equal columns) ---
        case .leftThird:   return tiled(CGRect(x: x0,            y: y0, width: W / 3, height: H))
        case .centerThird: return tiled(CGRect(x: x0 + W / 3,    y: y0, width: W / 3, height: H))
        case .rightThird:  return tiled(CGRect(x: x0 + 2 * W / 3, y: y0, width: W / 3, height: H))

        // --- Two-thirds (wider columns; 左 2/3 + 右 1/3 / 左 1/3 + 右 2/3 可拼满屏) ---
        case .leftTwoThirds:  return tiled(CGRect(x: x0,         y: y0, width: W * 2 / 3, height: H))
        case .rightTwoThirds: return tiled(CGRect(x: x0 + W / 3, y: y0, width: W * 2 / 3, height: H))

        case .maximize:    return vf // fill the whole visible area, no gap
        case .center:
            let cw = W * 0.6, ch = H * 0.6
            return CGRect(x: x0 + (W - cw) / 2, y: y0 + (H - ch) / 2, width: cw, height: ch)
        }
    }
}
