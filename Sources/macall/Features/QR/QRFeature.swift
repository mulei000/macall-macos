import AppKit
import CoreImage
import Foundation
import SwiftUI

// MARK: - 二维码（QR Code）

private final class QRPanelState: ObservableObject {
    @Published var text: String = ""
    @Published var generated: NSImage?

    func regenerate() {
        generated = QRFeature.generate(text: text)
    }
}

final class QRFeature: Feature {
    let id = "qr"
    let title = IadenteL10n.t("二维码", "QR Code")
    let category = FeatureCategory.other
    var enabledByDefault: Bool = true

    var isLaunchableTool: Bool { true }
    var launchAction: String? { "show" }

    private var context: AppContext?
    private var panel: QRPanelController?
    private var keyMonitor: Any?

    static func generate(text: String) -> NSImage? {
        guard !text.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(text.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSBitmapImageRep(ciImage: scaled)
        let img = NSImage()
        img.addRepresentation(rep)
        return img
    }

    fileprivate static func pngData(_ image: NSImage) -> Data? {
        guard let rep = image.representations.first as? NSBitmapImageRep ??
                NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[qr] 已安装：⌃⌥F 唤起二维码生成")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["qr.show"]?.toCombo()
            ?? Configuration.defaultHotkeys()["qr.show"]!.toCombo()
        context?.hotkeys.bind(featureId: id, action: "show", configKey: "qr.show", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "show" { togglePanel() }
    }

    func reload(config: Configuration) { bindHotkey(using: config) }
    func uninstall() { closePanel() }

    private func togglePanel() {
        if panel != nil { closePanel(); return }
        let p = QRPanelController()
        p.onClose = { [weak self] in self?.panel = nil; self?.removeKeyMonitor() }
        p.show()
        panel = p
        installKeyMonitor()
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        removeKeyMonitor()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            if event.keyCode == 53 { self.closePanel(); return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - 面板

private struct QRView: View {
    @ObservedObject var state: QRPanelState
    let onCopyImage: () -> Void
    let onSave: () -> Void
    let onCopyText: () -> Void

    /// 输入区固定高度：单行 TextField 装不下长网址（用户实测「文本框不随内容变大，
    /// 显示不全」）。改成固定 5 行左右的多行编辑器，超出部分自己滚动，
    /// 这样面板尺寸恒定、不会因为粘进一段长文本就把二维码挤出屏幕。
    private static let editorHeight: CGFloat = 92

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                if state.text.isEmpty {
                    Text(IadenteL10n.t("输入文本或网址", "Text or URL"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: Self.editorHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            // 边打字边出码，不用再按回车。
            .onChange(of: state.text) { _, _ in state.regenerate() }

            HStack {
                Text(IadenteL10n.t("\(state.text.count) 个字符", "\(state.text.count) chars"))
                Spacer()
                if state.generated == nil && !state.text.isEmpty {
                    Text(IadenteL10n.t("内容过长，无法生成", "Too long to encode"))
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let img = state.generated {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 240, height: 240)
                    .overlay(Text(IadenteL10n.t("输入内容后生成", "Type to generate"))
                        .foregroundStyle(.secondary))
            }

            HStack(spacing: 8) {
                Button(IadenteL10n.t("复制图片", "Copy Image"), action: onCopyImage)
                    .disabled(state.generated == nil)
                Button(IadenteL10n.t("保存 PNG", "Save PNG"), action: onSave)
                    .disabled(state.generated == nil)
                Button(IadenteL10n.t("复制文本", "Copy Text"), action: onCopyText)
                    .disabled(state.text.isEmpty)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 288)
    }
}

private final class QRPanelController: NSObject, NSWindowDelegate {
    let state = QRPanelState()
    var onClose: (() -> Void)?
    private var window: NSWindow?

    func show() {
        let initial = NSPasteboard.general.string(forType: .string) ?? ""
        state.text = initial
        state.regenerate()

        let view = QRView(
            state: state,
            onCopyImage: { [weak self] in self?.copyImage() },
            onSave: { [weak self] in self?.save() },
            onCopyText: { [weak self] in self?.copyText() })

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 288, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = IadenteL10n.t("二维码", "QR Code")
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.appearance = Defaults[.appearanceMode].nsAppearance
        win.contentViewController = NSHostingController(rootView: view)
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 144
            let y = screen.visibleFrame.midY - 235
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }
        win.makeKeyAndOrderFront(nil)
        // 菜单栏 accessory App 不激活就拿不到键盘焦点，输入框会打不进字。
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func copyImage() {
        guard let img = state.generated, let data = QRFeature.pngData(img) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }

    private func copyText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(state.text, forType: .string)
    }

    private func save() {
        guard let img = state.generated, let data = QRFeature.pngData(img) else { return }
        let dir = (try? URL(fileURLWithPath: Defaults[.screenshotSaveDirectory]).resourceValues(forKeys: [.isDirectoryKey])) != nil
            ? URL(fileURLWithPath: Defaults[.screenshotSaveDirectory])
            : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let name = "qrcode-\(Int(Date().timeIntervalSince1970)).png"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(dir)
        } catch {
            Log.warning("[qr] 保存失败: \(error)")
        }
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose?()
    }
}
