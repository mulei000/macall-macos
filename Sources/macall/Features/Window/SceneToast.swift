import AppKit
import SwiftUI

// MARK: - 场景保存瞬时提示

/// 保存场景等操作的瞬时提示：菜单栏下方弹出一个小浮层，约 1.6s 后自动消失。
/// 纯本功能自用，不触碰其他模块。
final class SceneToast {
    static let shared = SceneToast()
    private var panel: NSPanel?
    private var workItem: DispatchWorkItem?

    func show(_ message: String) {
        DispatchQueue.main.async { self.present(message) }
    }

    private func present(_ message: String) {
        workItem?.cancel()
        panel?.orderOut(nil)
        panel = nil

        let hosting = NSHostingController(rootView: SceneToastView(message: message))
        let w: CGFloat = 300, h: CGFloat = 52
        hosting.view.frame = NSRect(x: 0, y: 0, width: w, height: h)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting.view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - w / 2, y: visible.maxY - h - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let item = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }
}

private struct SceneToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(IadenteTheme.jade)
                .font(.system(size: 18))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
