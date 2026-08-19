import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    @Default(.appLanguage) var appLanguage
    @Default(.appearanceMode) var appearanceMode
    @Default(.launchAtLogin) var launchAtLogin
    @Default(.showDockIcon) var showDockIcon

    @State private var launchAlert: LaunchAlert?
    /// 回弹开关时阻止 onChange 二次触发导致的循环。
    @State private var suppressLoginToggle = false

    private enum LaunchAlert: Identifiable {
        case registerFailed
        case unregisterFailed
        var id: String { "\(self)" }
    }

    /// 全局总开关：关掉后所有模块的全局快捷键与行为触发一律透传给系统，
    /// 等于「一键休眠整个 macall」，但不改动任何单个模块的开关状态。
    private var masterBinding: Binding<Bool> {
        Binding(
            get: { model.config.enabled },
            set: {
                model.config.enabled = $0
                model.save()
            }
        )
    }

    var body: some View {
        IadenteSettingsPage {
            IadenteCard(
                IadenteL10n.t("总开关", "Master Switch"),
                subtitle: IadenteL10n.t(
                    "所有功能的最上层开关。关闭后 macall 的全部快捷键与自动行为立即停止，各模块自己的开关保持不变；重新打开即恢复原样。",
                    "The top-level switch for everything. Turning it off suspends all hotkeys and automatic behaviors while keeping each module's own state."
                ),
                icon: "power.circle.fill",
                colors: [IadenteTheme.jade, IadenteTheme.mint],
                trailing: {
                    Toggle("", isOn: masterBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(IadenteTheme.jade)
                },
                content: {
                    if !model.config.enabled {
                        IadenteNotice(
                            text: IadenteL10n.t(
                                "macall 当前处于暂停状态，所有快捷键都已交还给系统。",
                                "macall is paused — every hotkey is handed back to the system."),
                            icon: "pause.circle.fill",
                            colors: [IadenteTheme.amber, IadenteTheme.gold]
                        )
                    }
                }
            )

            IadenteCard(
                IadenteL10n.t("语言", "Language"),
                subtitle: IadenteL10n.t(
                    "切换菜单栏和设置界面的显示语言。",
                    "Follow macOS or choose the language used in the menu bar and settings."
                ),
                icon: "character.bubble.fill",
                colors: IadenteTheme.generalColors
            ) {
                Picker(IadenteL10n.t("语言"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .id(appLanguage)
            }

            IadenteCard(
                IadenteL10n.t("外观", "Appearance"),
                subtitle: IadenteL10n.t(
                    "选择 macall 使用日间、夜间或跟随系统外观。",
                    "Choose whether macall uses light, dark, or system appearance."
                ),
                icon: "circle.lefthalf.filled",
                colors: IadenteTheme.dashboardColors
            ) {
                Picker(IadenteL10n.t("外观"), selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .id(appLanguage)
            }

            IadenteCard(
                IadenteL10n.t("启动", "Startup"),
                subtitle: IadenteL10n.t(
                    "让 macall 在登录后自动开始工作。",
                    "Launch macall automatically after you log in."
                ),
                icon: "power.circle.fill",
                colors: IadenteTheme.generalColors
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    IadenteSettingToggle(
                        IadenteL10n.t("登录时启动 macall", "Launch macall at Login"),
                        subtitle: IadenteL10n.t(
                            "登录当前账户后自动显示菜单栏图标",
                            "Show the menu bar icon after signing in"
                        ),
                        icon: "arrow.up.forward.app.fill",
                        colors: IadenteTheme.generalColors,
                        isOn: $launchAtLogin
                    )

                    IadenteRowDivider()

                    IadenteSettingToggle(
                        IadenteL10n.t("在 Dock 中显示图标", "Show Icon in Dock"),
                        subtitle: IadenteL10n.t(
                            "点 Dock 图标即可打开设置；关闭后回到纯菜单栏模式",
                            "Click the Dock icon to open Settings; turn off for menu-bar-only mode"
                        ),
                        icon: "dock.rectangle",
                        colors: IadenteTheme.generalColors,
                        isOn: $showDockIcon
                    )

                    IadenteRowDivider()

                    Button {
                        openLoginItemsSettings()
                    } label: {
                        HStack(spacing: 6) {
                            Label(
                                IadenteL10n.t(
                                    "在系统设置中管理登录项",
                                    "Manage Login Items in System Settings"
                                ),
                                systemImage: "gear"
                            )
                            .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(IadenteL10n.t(
                        "若自动添加失败（如未使用正式签名，或应用不在「应用程序」文件夹），请点上方按钮在系统设置中手动勾选「登录时打开」。",
                        "If auto-add fails (e.g. not formally signed, or the app is outside Applications), use the button above to enable it manually in System Settings."
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            IadenteCard(
                IadenteL10n.t("权限", "Permissions"),
                subtitle: IadenteL10n.t(
                    "窗口分屏、隐藏、跨屏移动需要「辅助功能」；全局快捷键需要「输入监控」；Dock 预览需要「屏幕录制」。",
                    "Window management requires Accessibility; hotkeys require Input Monitoring; Dock preview requires Screen Recording."
                ),
                icon: "lock.shield.fill",
                colors: IadenteTheme.advancedColors
            ) {
                PermissionsPane()
            }

            FeatureModuleCard(model: model, featureID: "hotkeycheatsheet")
        }
        .onChange(of: launchAtLogin) { _, newValue in
            guard !suppressLoginToggle else {
                suppressLoginToggle = false
                return
            }
            let ok = LaunchAtLoginService.shared.setLaunchAtLogin(newValue)
            if !ok {
                // 注册/注销未生效：回弹开关以反映真实状态，并提示用户手动处理。
                suppressLoginToggle = true
                launchAtLogin = !newValue
                launchAlert = newValue ? .registerFailed : .unregisterFailed
            }
        }
        .alert(item: $launchAlert) { alert in
            switch alert {
            case .registerFailed:
                return Alert(
                    title: Text(
                        IadenteL10n.t(
                            "无法自动添加到登录项",
                            "Can't Add to Login Items"
                        )
                    ),
                    message: Text(
                        IadenteL10n.t(
                            "可能是应用未使用正式签名，或不在「应用程序」文件夹。可点下方按钮在系统设置中手动勾选「登录时打开」。",
                            "The app may not be formally signed, or isn't in the Applications folder. Open System Settings and enable it manually under Login Items."
                        )
                    ),
                    primaryButton: .default(
                        Text(IadenteL10n.t("去系统设置添加", "Open System Settings"))
                    ) { openLoginItemsSettings() },
                    secondaryButton: .cancel()
                )
            case .unregisterFailed:
                return Alert(
                    title: Text(
                        IadenteL10n.t(
                            "无法关闭登录启动",
                            "Can't Disable Login Item"
                        )
                    ),
                    message: Text(
                        IadenteL10n.t(
                            "请到系统设置 → 通用 → 登录项，手动移除 macall。",
                            "Remove macall manually in System Settings → General → Login Items."
                        )
                    )
                )
            }
        }
    }

    private func openLoginItemsSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

// MARK: - 权限诊断面板

private struct PermissionsPane: View {
    @State private var accessibilityOK = false
    @State private var inputOK = false
    @State private var screenOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PermissionRow(
                title: IadenteL10n.t("辅助功能", "Accessibility"),
                subtitle: IadenteL10n.t(
                    "窗口分屏、隐藏、跨屏移动所需",
                    "Required for window snapping, hiding, and display move"
                ),
                isGranted: accessibilityOK,
                openAction: Permissions.openAccessibilitySettings
            )
            PermissionRow(
                title: IadenteL10n.t("输入监控", "Input Monitoring"),
                subtitle: IadenteL10n.t(
                    "全局快捷键所需",
                    "Required for global hotkeys"
                ),
                isGranted: inputOK,
                openAction: Permissions.openInputMonitoringSettings
            )
            PermissionRow(
                title: IadenteL10n.t("屏幕录制", "Screen Recording"),
                subtitle: IadenteL10n.t(
                    "Dock 预览缩略图所需",
                    "Required for Dock preview thumbnails"
                ),
                isGranted: screenOK,
                openAction: Permissions.openScreenRecordingSettings
            )

            Divider()

            Button(IadenteL10n.t("重新检测", "Recheck")) {
                refresh()
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        accessibilityOK = Permissions.isAccessibilityWorking()
        inputOK = Permissions.inputMonitoringGranted
        screenOK = Permissions.isScreenRecordingTrusted()
    }
}

}
