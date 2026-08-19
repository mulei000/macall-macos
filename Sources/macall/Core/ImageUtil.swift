import AppKit
import CoreGraphics

/// Thin shim so `ThumbnailCache` (ported from Macindow) can capture a window
/// thumbnail through the SAME engine the Dock-hover preview uses — the verbatim
/// Vorssaint `WindowPreviewProvider` — instead of Macindow's separate
/// `ImageUtil`. Same capture path, no extra port.
enum ImageUtil {
    static func windowThumbnail(wid: CGWindowID, maxDim: CGFloat) -> NSImage? {
        guard let cg = WindowPreviewProvider.captureViaWindowServer(wid) else { return nil }
        let ns = NSImage(cgImage: cg,
                         size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ns.scaledToMaxDimension(maxDim) ?? ns
    }
}

extension NSImage {
    /// Downscale to at most `maxDim` on the longest side (keeps thumbnail memory
    /// bounded) while preserving aspect ratio. Returns `nil` when already small
    /// enough, so callers coalesce with the original image.
    func scaledToMaxDimension(_ maxDim: CGFloat) -> NSImage? {
        let longest = max(size.width, size.height)
        guard longest > maxDim, longest > 0 else { return nil }
        let scale = maxDim / longest
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let img = NSImage(size: newSize)
        img.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: newSize).fill()
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy, fraction: 1)
        img.unlockFocus()
        return img
    }
}
