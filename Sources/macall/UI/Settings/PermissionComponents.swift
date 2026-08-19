import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置页「板块级」权限描述。
///
/// 与通用页的「全部权限汇总」不同，这里只描述某个设置板块实际用到的权限，
/// 让用户在对应功能页底部一眼看到「这部分需要哪些授权」，无需切回通用页。
enum RequiredPermission: Hashable {
    case accessibility
    case inputMonitoring
    case screenRecording

    var title: String {
        switch self {
        case .accessibility:   return IadenteL10n.t("辅助功能", "Accessibility")
        case .inputMonitoring: return IadenteL10n.t("输入监控", "Input Monitoring")
        case .screenRecording: return IadenteL10n.t("屏幕录制", "Screen Recording")
        }
    }

    var subtitle: String {
        switch self {
        case .accessibility:   return IadenteL10n.t("窗口分屏、隐藏、跨屏移动所需", "Required for window snapping, hiding, display move")
        case .inputMonitoring: return IadenteL10n.t("全局快捷键所需", "Required for global hotkeys")
        case .screenRecording: return IadenteL10n.t("Dock 预览缩略图所需", "Required for Dock preview thumbnails")
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility:   return Permissions.isAccessibilityWorking()
        case .inputMonitoring: return Permissions.inputMonitoringGranted
        case .screenRecording: return Permissions.isScreenRecordingTrusted()
        }
    }

    var openAction: () -> Void {
        switch self {
        case .accessibility:   return Permissions.openAccessibilitySettings
        case .inputMonitoring: return Permissions.openInputMonitoringSettings
        case .screenRecording: return Permissions.openScreenRecordingSettings
        }
    }
}

/// 单个权限行（与通用页权限面板共用同一视觉语言）。
struct PermissionRow: View {
    @Default(.appLanguage) private var appLanguage
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let isGranted: Bool
    let openAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isGranted ? IadenteTheme.jade : Color.secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text(isGranted ? IadenteL10n.t("已授权", "Granted") : IadenteL10n.t("未授权", "Not granted"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isGranted ? IadenteTheme.jade : .secondary)
                Button(IadenteL10n.t("去开启", "Open")) {
                    openAction()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
    }
}

/// 板块底部的「本部分用到的权限」汇总卡。
///
/// 由 `IadenteSettingsPage` 根据当前 tab 的 `requiredPermissions` 自动追加在
/// 页面内容之后（位于滚动区域内），通用页因其汇总为空而不会重复展示。
struct SectionPermissionFooter: View {
    let tab: MacallSettingsTab
    @State private var states: [RequiredPermission: Bool] = [:]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let permissions = tab.requiredPermissions
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IadenteTheme.advancedColors.first ?? IadenteTheme.jade)
                Text(IadenteL10n.t("本部分用到的权限", "Permissions used by this section"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button(IadenteL10n.t("重新检测", "Recheck")) { refresh(permissions) }
                    .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(permissions, id: \.self) { p in
                    PermissionRow(
                        title: p.title,
                        subtitle: p.subtitle,
                        isGranted: states[p, default: false],
                        openAction: p.openAction
                    )
                }
            }

            // 拖拽授权区：只要本部分还有未授予的权限就显示。
            // 跳转的面板取「第一个未授予的权限」（通常就是辅助功能这一关键项）。
            if !permissions.isEmpty,
               permissions.contains(where: { states[$0, default: false] == false }) {
                Divider()
                PermissionDropZone(
                    permission: permissions.first(where: { states[$0, default: false] == false })
                        ?? permissions.first!
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: colorScheme == .dark
                            ? NSColor(calibratedRed: 0.13, green: 0.125, blue: 0.12, alpha: 1)
                            : NSColor(calibratedWhite: 0.98, alpha: 1)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08))
        )
        .onAppear { refresh(permissions) }
    }

    private func refresh(_ permissions: [RequiredPermission]) {
        // 辅助功能 / 输入监控 / 屏幕录制 等权限检测放到后台，确保主线程永不阻塞。
        DispatchQueue.global(qos: .userInitiated).async {
            var next: [RequiredPermission: Bool] = [:]
            for p in permissions { next[p] = p.isGranted }
            DispatchQueue.main.async { self.states = next }
        }
    }
}

/// 「拖拽授权」区：用户把 macall.app 从访达 / 应用程序拖进来，
/// 校验确为 macall 本尊后自动跳转对应系统设置隐私面板（TCC 只允许用户在面板里翻开关）。
///
/// macOS 限制：第三方 app 无法自填白名单，所以这里只做「确认身份 + 一键到位」，
/// 不替代用户在系统设置里的手动授权动作。
struct PermissionDropZone: View {
    let permission: RequiredPermission
    @Environment(\.colorScheme) private var colorScheme

    @State private var isTargeted = false
    @State private var state: DropState = .idle

    enum DropState {
        case idle
        case ok
        case wrong
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(fillColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(strokeColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var iconName: String {
        switch state {
        case .idle:  return "app.dock.rectangle"
        case .ok:    return "checkmark.circle.fill"
        case .wrong: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch state {
        case .idle:  return isTargeted ? Color.accentColor : Color.secondary
        case .ok:    return IadenteTheme.jade
        case .wrong: return Color.red
        }
    }

    private var fillColor: Color {
        switch state {
        case .idle:  return isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)
        case .ok:    return IadenteTheme.jade.opacity(0.12)
        case .wrong: return Color.red.opacity(0.10)
        }
    }

    private var strokeColor: Color {
        switch state {
        case .idle:  return isTargeted ? Color.accentColor : Color.primary.opacity(0.18)
        case .ok:    return IadenteTheme.jade
        case .wrong: return Color.red
        }
    }

    private var titleText: String {
        switch state {
        case .idle:  return IadenteL10n.t("拖入 macall 自动授权", "Drag macall to authorize")
        case .ok:    return IadenteL10n.t("已识别 macall ✓", "macall detected ✓")
        case .wrong: return IadenteL10n.t("这不是 macall", "That's not macall")
        }
    }

    private var subText: String {
        switch state {
        case .idle:  return IadenteL10n.t("把 macall.app 从访达 / 应用程序拖到这里", "Drag macall.app from Finder / Applications here")
        case .ok:    return IadenteL10n.t("已为你打开「\(permission.title)」设置", "Opened \(permission.title) settings for you")
        case .wrong: return IadenteL10n.t("请拖入 macall 本尊再试", "Please drag macall itself")
        }
    }

    /// 返回 true 表示我们认领了这个 drop（即便内容不合法，也吞掉避免系统报错）。
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async {
                if Permissions.isMacallBundle(url) {
                    state = .ok
                    // 身份确认后跳转对应隐私面板，用户只需把开关打开即可。
                    permission.openAction()
                } else {
                    state = .wrong
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if state == .wrong { state = .idle }
                    }
                }
            }
        }
        return true
    }
}
