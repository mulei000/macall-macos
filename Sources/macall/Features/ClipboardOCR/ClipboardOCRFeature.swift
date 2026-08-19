import AppKit
import Foundation
import SwiftUI
import Vision

// MARK: - 剪贴板 OCR（图片转文字）

/// ⌃⌥N：读取剪贴板中的图片，用 Vision 的 VNRecognizeTextRequest 识别文字，
/// 自动复制到剪贴板，并在小面板展示识别结果。无额外权限（Vision 本地推理）。
final class ClipboardOCRFeature: Feature {
    let id = "clipboardocr"
    var title: String { IadenteL10n.t("剪贴板 OCR", "Clipboard OCR") }
    let category = FeatureCategory.other
    var enabledByDefault: Bool = true

    private var context: AppContext?
    private var panel: OcrPanelController?
    private var keyMonitor: Any?

    func install(context: AppContext) {
        self.context = context
        bindHotkey(using: context.config)
        Log.info("[clipboardocr] 已安装：⌃⌥N 识别剪贴板图片中的文字")
    }

    private func bindHotkey(using config: Configuration) {
        let combo = config.hotkeys["clipboardocr.run"]?.toCombo()
            ?? Configuration.defaultHotkeys()["clipboardocr.run"]!.toCombo()
        context?.hotkeys.bind(featureId: id, action: "run", configKey: "clipboardocr.run", defaultCombo: combo)
    }

    func handle(action: String) {
        if action == "run" { runOCR() }
    }

    func reload(config: Configuration) { bindHotkey(using: config) }
    func uninstall() { panel?.close() }

    private func runOCR() {
        let pb = NSPasteboard.general
        guard let image = NSImage(pasteboard: pb),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showResult(text: nil, error: IadenteL10n.t("剪贴板当前没有图片", "No image on the clipboard"))
            return
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            showResult(text: nil, error: IadenteL10n.t("识别失败：", "Recognition failed: ") + error.localizedDescription)
            return
        }

        let lines = (request.results ?? []).compactMap { obs in
            obs.topCandidates(1).first?.string
        }.filter { !$0.isEmpty }

        if lines.isEmpty {
            showResult(text: nil, error: IadenteL10n.t("未识别到文字", "No text recognized"))
            return
        }
        let text = lines.joined(separator: "\n")
        pb.clearContents()
        pb.setString(text, forType: .string)
        showResult(text: text, error: nil)
    }

    private func showResult(text: String?, error: String?) {
        panel?.close()
        let p = OcrPanelController(text: text, error: error)
        p.onClose = { [weak self] in self?.panel = nil; self?.removeKeyMonitor() }
        p.show()
        panel = p
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            if event.keyCode == 53 { self.panel?.close(); return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - 面板

private final class OcrPanelController: NSObject, NSWindowDelegate {
    let text: String?
    let error: String?
    var onClose: (() -> Void)?
    private var window: NSWindow?

    init(text: String?, error: String?) {
        self.text = text
        self.error = error
    }

    func show() {
        let view = OcrView(text: text, error: error)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = IadenteL10n.t("剪贴板 OCR", "Clipboard OCR")
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.appearance = Defaults[.appearanceMode].nsAppearance
        win.contentViewController = NSHostingController(rootView: view)
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 210
            let y = screen.visibleFrame.midY + 160
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }
        win.makeKeyAndOrderFront(nil)
        window = win
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

private struct OcrView: View {
    let text: String?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error {
                Text(error)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
            } else if let text {
                HStack {
                    Text(IadenteL10n.t("识别完成，已复制到剪贴板", "Done — copied to clipboard"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(IadenteL10n.t("再复制一次", "Copy Again")) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(width: 420, height: 320)
    }
}
