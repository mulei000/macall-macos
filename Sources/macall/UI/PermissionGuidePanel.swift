import AppKit
import Observation
import SwiftUI

// MARK: - 启动权限引导浮层（拖拽授权版）

/// 冷启动发现「辅助功能」缺失时弹出的引导面板。取代原先的 `NSAlert`，
/// 改为 borderless + nonactivating 浮层，并内嵌「拖入 macall 自动授权」拖拽区。
///
/// 由于 macOS TCC 不允许第三方 app 自填白名单，浮层无法替用户翻开关；
/// 它做的是：① 解释为什么需要这项权限；② 让用户把 macall.app 拖进来，
/// 确认身份后自动跳到「辅助功能」隐私面板；③ 仍提供「打开系统设置 / 已授权重启 / 稍后」三个按钮。

/// 浮层面板。需要能成为 key 窗口才能接收交互，但 `.nonactivatingPanel`
/// 避免点一下就把 macall 整个激活到最前、抢走当前窗口焦点。
final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 引导控制器（单例，主线程）。负责面板创建 / 定位 / 关闭 / 三个按钮动作。
@Observable
final class PermissionGuideController {
    static let shared = PermissionGuideController()

    private(set) var panel: PermissionGuidePanel?
    private var hosting: NSHostingController<PermissionGuideView>?
    private var resignObserver: NSObjectProtocol?
    /// 打开浮层前处于前台的 App，关闭时把焦点还给它（避免抢焦点）。
    private var previousApp: NSRunningApplication?

    static let width: CGFloat = 460
    static let height: CGFloat = 372

    private init() {}

    // MARK: - 显隐

    func show() {
        guard panel == nil else { return }
        let view = PermissionGuideView(controller: self)
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)

        let panel = PermissionGuidePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting.view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // 记下当前前台 App，关闭时还回焦点
        previousApp = NSWorkspace.shared.frontmostApplication
        // 让 macall 成为活跃 App，否则非激活面板拿不到 key window。
        NSApp.activate(ignoringOtherApps: true)
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.hosting = hosting
        installDismissHooks(panel)
        Log.info("[permission] 启动权限引导浮层已弹出（辅助功能缺失）")
    }

    /// 屏幕正中（水平 + 垂直居中）。
    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = visible.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 关闭

    func close() {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        if let prev = previousApp {
            prev.activate()
            previousApp = nil
        }
    }

    /// 失焦（点了别处或跳去系统设置）就收起；避免覆盖层一直挂着。
    private func installDismissHooks(_ panel: PermissionGuidePanel) {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main)
        { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
    }

    // MARK: - 按钮动作

    /// 「打开系统设置」：跳转辅助功能隐私面板。
    func openSettings() {
        Permissions.openAccessibilitySettings()
    }

    /// 「已授权，重启 macall」：授权后必须重启进程才能让 AX / EventTap 生效
    ///（macOS 不会给已运行进程补发权限）。先开新实例，旧实例的单实例保护会让它自己退出。
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 视图

struct PermissionGuideView: View {
    var controller: PermissionGuideController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(IadenteTheme.advancedColors.first ?? IadenteTheme.jade)
                Text(IadenteL10n.t("macall 缺少「辅助功能」权限", "macall needs Accessibility access"))
                    .font(.system(size: 15, weight: .bold))
            }
            .padding(.top, 18)
            .padding(.horizontal, 20)

            // 说明
            Text(IadenteL10n.t(
                "未授予辅助功能权限时，全局快捷键与全部窗口操作都会静默失效（表现为「所有功能都用不了」）。\n\n把 macall.app 拖到下方区域可自动打开对应隐私设置；随后在系统设置里把开关打开即可。",
                "Without Accessibility, all global hotkeys and window operations silently fail (it looks like 'nothing works'). Drag macall.app below to open the right privacy pane, then flip the switch."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.horizontal, 20)

            // 拖拽授权区
            PermissionDropZone(permission: .accessibility)
                .padding(.top, 14)
                .padding(.horizontal, 20)

            Spacer(minLength: 0)

            Divider()

            // 按钮
            HStack(spacing: 10) {
                Button(IadenteL10n.t("打开系统设置", "Open System Settings")) {
                    controller.openSettings()
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)

                Button(IadenteL10n.t("已授权，重启 macall", "Authorized, restart macall")) {
                    controller.relaunch()
                }
                .controlSize(.regular)

                Spacer(minLength: 0)

                Button(IadenteL10n.t("稍后", "Later")) {
                    controller.close()
                }
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: PermissionGuideController.width, height: PermissionGuideController.height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThickMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
